package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/sync/errgroup"
)

// keyRange is a half-open interval of key values: lo <= key < hi.
// A nil bound is open. The first range has no lower bound and the last one
// no upper bound, so rows outside a stale histogram are still covered.
type keyRange struct {
	lo, hi *int64
}

// condition returns the SQL condition for the range, or "" for the
// unbounded range. Bounds are integers, so they are inlined as literals.
func (r keyRange) condition(pk string) string {
	var c []string
	if r.lo != nil {
		c = append(c, fmt.Sprintf("%s >= %d", pk, *r.lo))
	}
	if r.hi != nil {
		c = append(c, fmt.Sprintf("%s < %d", pk, *r.hi))
	}
	return strings.Join(c, " AND ")
}

// rangesFromBounds turns histogram bounds b0 < b1 < ... < bk into k ranges,
// one per bin: (-inf, b1), [b1, b2), ..., [b(k-1), +inf).
func rangesFromBounds(b []int64) []keyRange {
	if len(b) < 2 {
		return []keyRange{{}}
	}
	rs := make([]keyRange, 0, len(b)-1)
	for i := 1; i < len(b); i++ {
		var r keyRange
		if i > 1 {
			r.lo = &b[i-1]
		}
		if i < len(b)-1 {
			r.hi = &b[i]
		}
		rs = append(rs, r)
	}
	return rs
}

// histogram returns the histogram bounds of the key column, or nil if the
// table has not been analysed. The key is unique, so there are no most
// common values and the histogram describes the whole table.
func (s *side) histogram(ctx context.Context, d *description, col string) ([]int64, error) {
	var b []int64
	err := s.tx.QueryRow(ctx, `
		SELECT histogram_bounds::text::int8[]
		FROM pg_catalog.pg_stats
		WHERE schemaname = $1 AND tablename = $2 AND attname = $3 AND NOT inherited`,
		d.schema, d.name, col).Scan(&b)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("%s: histogram of %s.%s: %w", s.name, d.qualifiedName(), col, err)
	}
	return b, nil
}

// isTooManyConnections reports whether a connection attempt was refused
// because the server is out of connection slots (SQLSTATE 53300).
func isTooManyConnections(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "53300"
}

func (s *side) exportSnapshot(ctx context.Context) (string, error) {
	var id string
	if err := s.tx.QueryRow(ctx, "SELECT pg_catalog.pg_export_snapshot()").Scan(&id); err != nil {
		return "", fmt.Errorf("%s: export snapshot: %w", s.name, err)
	}
	return id, nil
}

// runRange streams both sides concurrently and merges them.
//
// errgroup cancels gctx as soon as any of the three goroutines fails;
// readers blocked on a full channel then wake up and exit. Wait returns the
// first error, which is the real cause.
func runRange(ctx context.Context, ref, tst *side, q1, q2 string, w io.Writer) (stats, error) {
	g, gctx := errgroup.WithContext(ctx)
	ch1 := make(chan row, bufferRows)
	ch2 := make(chan row, bufferRows)
	var st stats

	g.Go(func() error { return ref.stream(gctx, q1, ch1) })
	g.Go(func() error { return tst.stream(gctx, q2, ch2) })
	g.Go(func() error {
		var err error
		st, err = merge(ch1, ch2, w)
		return err
	})
	err := g.Wait()
	return st, err
}

// runParallel compares the ranges with up to opt.jobs workers.
//
// Each side exports the snapshot of its coordinator transaction, and every
// worker imports it, so all sessions of one side see exactly the same data.
// A worker is a pair of connections (reference + test) that takes ranges
// from a queue one by one. Each range writes its report to a temporary
// file; at the end the files are appended to w in range order, so the
// report stays sorted by key.
func runParallel(ctx context.Context, opt *options, ref, tst *side, ranges []keyRange,
	query func(side int, r keyRange) string, tmpDir string, w io.Writer) (stats, error) {

	snap1, err := ref.exportSnapshot(ctx)
	if err != nil {
		return stats{}, err
	}
	snap2, err := tst.exportSnapshot(ctx)
	if err != nil {
		return stats{}, err
	}

	type result struct {
		st   stats
		path string
	}
	results := make([]result, len(ranges))
	defer func() {
		for _, r := range results {
			if r.path != "" {
				os.Remove(r.path)
			}
		}
	}()

	// Open all worker connections up front. If a server runs out of
	// connection slots, go on with the workers that did connect: fewer
	// workers is slower but still correct.
	type pair struct{ ref, tst *side }
	var pairs []pair
	defer func() {
		for _, p := range pairs {
			p.ref.close()
			p.tst.close()
		}
	}()
	for n := 0; n < min(opt.jobs, len(ranges)); n++ {
		a, err := openSide(ctx, "reference", opt.dsn1, snap1)
		if err == nil {
			var b *side
			if b, err = openSide(ctx, "test", opt.dsn2, snap2); err == nil {
				pairs = append(pairs, pair{a, b})
				continue
			}
			a.close()
		}
		if len(pairs) > 0 && isTooManyConnections(err) {
			log.Printf("warning: only %d of %d workers could connect: %v", len(pairs), min(opt.jobs, len(ranges)), err)
			break
		}
		return stats{}, err
	}

	g, gctx := errgroup.WithContext(ctx)

	queue := make(chan int)
	g.Go(func() error {
		defer close(queue)
		for i := range ranges {
			select {
			case queue <- i:
			case <-gctx.Done():
				return gctx.Err()
			}
		}
		return nil
	})

	for _, p := range pairs {
		a, b := p.ref, p.tst
		g.Go(func() error {
			// Each index comes out of the queue once, so results[i] has a
			// single writer; it is read only after g.Wait.
			for i := range queue {
				f, err := os.CreateTemp(tmpDir, ".pgcmp-*.part")
				if err != nil {
					return fmt.Errorf("create temporary report: %w", err)
				}
				results[i].path = f.Name()
				bw := bufio.NewWriter(f)
				st, err := runRange(gctx, a, b, query(0, ranges[i]), query(1, ranges[i]), bw)
				if err == nil {
					err = bw.Flush()
				}
				if cerr := f.Close(); err == nil {
					err = cerr
				}
				if err != nil {
					return err
				}
				results[i].st = st
			}
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return stats{}, err
	}

	var total stats
	for _, r := range results {
		total.add(r.st)
		f, err := os.Open(r.path)
		if err != nil {
			return total, fmt.Errorf("read temporary report: %w", err)
		}
		_, err = io.Copy(w, f)
		f.Close()
		if err != nil {
			return total, fmt.Errorf("write report: %w", err)
		}
	}
	return total, nil
}
