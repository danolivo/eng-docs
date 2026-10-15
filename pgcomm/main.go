// pgcmp compares one table on two PostgreSQL instances by streaming both
// sides in primary-key order and merging the streams.
//
// Row contents are compared as the server's own text representation of
// ROW(col1, col2, ...) — i.e. what psql prints for a composite value — so
// no type conversion happens on the client side. Both sessions are
// configured with identical output-affecting settings (TimeZone,
// DateStyle, ...) before the comparison starts.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sync/errgroup"
)

const (
	exitMatch = 0
	exitDiff  = 1
	exitError = 2
)

// Rows each reader may run ahead of the merger. A full channel blocks the
// reader, which stops reading the socket, so client memory stays bounded
// no matter how far the two tables diverge.
const bufferRows = 4096

type options struct {
	dsn1, dsn2 string
	table      string
	columns    []string
	filter     string
	out        string
}

func main() {
	os.Exit(run())
}

func run() int {
	log.SetFlags(0)
	log.SetPrefix("pgcmp: ")

	var opt options
	var cols string
	flag.StringVar(&opt.dsn1, "dsn1", "", "connection string of the reference instance")
	flag.StringVar(&opt.dsn2, "dsn2", "", "connection string of the instance under test")
	flag.StringVar(&opt.table, "table", "", "table name, optionally schema-qualified")
	flag.StringVar(&cols, "columns", "", "comma-separated columns to compare (default: all columns of the reference table)")
	flag.StringVar(&opt.filter, "filter", "", "WHERE expression applied on both sides")
	flag.StringVar(&opt.out, "out", "pgcmp.out", "report file")
	flag.Parse()

	// Parsing stops at the first non-flag argument; everything after it
	// (including any further -flags) lands in flag.Args() unparsed.
	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "pgcmp: unexpected arguments: %q\n", flag.Args())
		flag.Usage()
		return exitError
	}

	if opt.dsn1 == "" || opt.dsn2 == "" || opt.table == "" {
		fmt.Fprintln(os.Stderr, "usage: pgcmp -dsn1 <dsn> -dsn2 <dsn> -table <name> [-columns a,b,c] [-filter <expr>] [-out <file>]")
		return exitError
	}
	for _, c := range strings.Split(cols, ",") {
		if c = strings.TrimSpace(c); c != "" {
			opt.columns = append(opt.columns, c)
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := compare(ctx, &opt)
	if err != nil {
		log.Printf("error: %v", err)
		return exitError
	}

	log.Printf("reference: %d rows, test: %d rows", st.rows1, st.rows2)
	if st.diffs() == 0 {
		log.Printf("match")
		return exitMatch
	}
	log.Printf("mismatch: %d differ, %d only in reference, %d only in test (see %s)",
		st.differ, st.onlyLeft, st.onlyRight, opt.out)
	return exitDiff
}

func compare(ctx context.Context, opt *options) (stats, error) {
	started := time.Now()

	// 1. Connect both sides and align session settings.
	ref, err := openSide(ctx, "reference", opt.dsn1)
	if err != nil {
		return stats{}, err
	}
	defer ref.close()
	tst, err := openSide(ctx, "test", opt.dsn2)
	if err != nil {
		return stats{}, err
	}
	defer tst.close()

	// 2. Negotiate the table structure.
	d1, err := ref.describe(ctx, opt.table)
	if err != nil {
		return stats{}, err
	}
	d2, err := tst.describe(ctx, opt.table)
	if err != nil {
		return stats{}, err
	}
	p, err := negotiate(d1, d2, opt.columns)
	if err != nil {
		return stats{}, err
	}
	log.Printf("key: %s (%s); columns: %s", p.pk, p.pkType, strings.Join(p.cols, ", "))

	// The table is resolved; now pin search_path so that both sides see the
	// same objects while the comparison runs.
	if err := ref.pinSearchPath(ctx, d1.schema); err != nil {
		return stats{}, err
	}
	if err := tst.pinSearchPath(ctx, d2.schema); err != nil {
		return stats{}, err
	}

	q1 := buildQuery(d1.qualifiedName(), p, opt.filter)
	q2 := buildQuery(d2.qualifiedName(), p, opt.filter)
	log.Printf("reference query: %s", q1)
	if q2 != q1 {
		log.Printf("test query: %s", q2)
	}

	// 3. Open the report.
	f, err := os.Create(opt.out)
	if err != nil {
		return stats{}, fmt.Errorf("create report: %w", err)
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)

	// 4. Stream both sides concurrently and merge.
	//
	// errgroup cancels gctx as soon as any of the three goroutines fails;
	// readers blocked on a full channel then wake up and exit. Wait returns
	// the first error, which is the real cause.
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
	if err := g.Wait(); err != nil {
		return st, err
	}

	if st.diffs() == 0 {
		if _, err := w.WriteString("match\n"); err != nil {
			return st, fmt.Errorf("write report: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		return st, fmt.Errorf("write report: %w", err)
	}
	if err := f.Sync(); err != nil {
		return st, fmt.Errorf("sync report: %w", err)
	}
	log.Printf("done in %s", time.Since(started).Round(time.Millisecond))
	return st, nil
}
