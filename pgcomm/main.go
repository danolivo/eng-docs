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
	"path/filepath"
	"strings"
	"syscall"
	"time"
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
	jobs       int
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
	flag.StringVar(&cols, "columns", "", "comma-separated columns to compare (default: columns present on both sides)")
	flag.StringVar(&opt.filter, "filter", "", "WHERE expression applied on both sides")
	flag.StringVar(&opt.out, "out", "pgcmp.out", "report file")
	flag.IntVar(&opt.jobs, "j", 1, "parallel workers; key ranges come from the reference histogram")
	flag.Parse()

	// Parsing stops at the first non-flag argument; everything after it
	// (including any further -flags) lands in flag.Args() unparsed.
	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "pgcmp: unexpected arguments: %q\n", flag.Args())
		flag.Usage()
		return exitError
	}

	if opt.dsn1 == "" || opt.dsn2 == "" || opt.table == "" || opt.jobs < 1 {
		fmt.Fprintln(os.Stderr, "usage: pgcmp -dsn1 <dsn> -dsn2 <dsn> -table <name> [-columns a,b,c] [-filter <expr>] [-j N] [-out <file>]")
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
	ref, err := openSide(ctx, "reference", opt.dsn1, "")
	if err != nil {
		return stats{}, err
	}
	defer ref.close()
	tst, err := openSide(ctx, "test", opt.dsn2, "")
	if err != nil {
		return stats{}, err
	}
	defer tst.close()
	if err := checkEncodings(ref.encoding, tst.encoding); err != nil {
		return stats{}, err
	}
	if w := versionWarning(ref.version, tst.version); w != "" {
		log.Print(w)
	}

	// 2. Negotiate the table structure.
	d1, err := ref.describe(ctx, opt.table)
	if err != nil {
		return stats{}, err
	}
	d2, err := tst.describe(ctx, opt.table)
	if err != nil {
		return stats{}, err
	}
	// The reference server decides on common types for mismatching columns.
	p, err := negotiate(d1, d2, opt.columns, func(c1, c2 column) (string, error) {
		return ref.commonType(ctx, c1, c2)
	})
	if err != nil {
		return stats{}, err
	}
	names := make([]string, len(p.cols))
	for i, c := range p.cols {
		names[i] = c.name
	}
	log.Printf("key: %s (%s); columns: %s", p.pk, p.pkType, strings.Join(names, ", "))
	if len(p.ignored) > 0 {
		log.Printf("ignored (present on one side only): %s", strings.Join(p.ignored, ", "))
	}

	query := func(side int, r keyRange) string {
		if side == 0 {
			return buildQuery(d1.qualifiedName(), p, 0, opt.filter, r)
		}
		return buildQuery(d2.qualifiedName(), p, 1, opt.filter, r)
	}
	log.Printf("reference query: %s", query(0, keyRange{}))
	if q2 := query(1, keyRange{}); q2 != query(0, keyRange{}) {
		log.Printf("test query: %s", q2)
	}

	// 3. Split the key space by the histogram of the reference side.
	ranges := []keyRange{{}}
	if opt.jobs > 1 {
		bounds, err := ref.histogram(ctx, d1, p.pk)
		if err != nil {
			return stats{}, err
		}
		if len(bounds) < 2 {
			log.Printf("warning: no histogram for %s.%s on the reference side (run ANALYZE); running without parallelism",
				d1.qualifiedName(), p.pk)
		} else {
			ranges = rangesFromBounds(bounds)
			log.Printf("parallel: %d workers, %d key ranges from the histogram",
				min(opt.jobs, len(ranges)), len(ranges))
		}
	}

	// 4. Check that each side will read the rows in key order through the
	// primary key index rather than scan and sort the table.
	for i, s := range []*side{ref, tst} {
		qs := make([]string, len(ranges))
		for j, r := range ranges {
			qs[j] = query(i, r)
		}
		table := []*description{d1, d2}[i].qualifiedName()
		w, err := s.checkPlans(ctx, table, qs)
		if err != nil {
			return stats{}, err
		}
		if w != "" {
			log.Print(w)
		}
	}

	// 5. Open the report.
	f, err := os.Create(opt.out)
	if err != nil {
		return stats{}, fmt.Errorf("create report: %w", err)
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)

	// 6. Compare: in the coordinator sessions, or in parallel workers.
	var st stats
	if len(ranges) == 1 {
		st, err = runRange(ctx, ref, tst, query(0, ranges[0]), query(1, ranges[0]), w)
	} else {
		st, err = runParallel(ctx, opt, ref, tst, ranges, query, filepath.Dir(opt.out), w)
	}
	if err != nil {
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
