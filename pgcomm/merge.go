package main

import (
	"fmt"
	"io"
	"strconv"
)

type stats struct {
	rows1, rows2 uint64 // rows read from the reference / test side
	differ       uint64 // same key, different row text
	onlyLeft     uint64 // key present only on the reference side
	onlyRight    uint64 // key present only on the test side
}

func (s stats) diffs() uint64 { return s.differ + s.onlyLeft + s.onlyRight }

// merge consumes two key-ordered streams and writes one report line per
// mismatch: <key> <reference row> <test row>, with NULL standing for a
// row that is absent on one side. It returns when both channels are closed.
//
// A space is a safe separator: record_out double-quotes any field that
// contains whitespace, so a row's text never has a bare space in it. A row
// always starts with '(', so it cannot be confused with the NULL marker.
func merge(in1, in2 <-chan row, w io.Writer) (stats, error) {
	var st stats
	recv1 := func() (row, bool) {
		r, ok := <-in1
		if ok {
			st.rows1++
		}
		return r, ok
	}
	recv2 := func() (row, bool) {
		r, ok := <-in2
		if ok {
			st.rows2++
		}
		return r, ok
	}
	report := func(key int64, left, right string) error {
		_, err := fmt.Fprintf(w, "%s %s %s\n", strconv.FormatInt(key, 10), left, right)
		if err != nil {
			return fmt.Errorf("write report: %w", err)
		}
		return nil
	}

	r1, ok1 := recv1()
	r2, ok2 := recv2()
	for ok1 || ok2 {
		var err error
		switch {
		case ok1 && ok2 && r1.key == r2.key:
			if r1.data != r2.data {
				st.differ++
				err = report(r1.key, r1.data, r2.data)
			}
			r1, ok1 = recv1()
			r2, ok2 = recv2()
		case ok1 && (!ok2 || r1.key < r2.key):
			st.onlyLeft++
			err = report(r1.key, r1.data, "NULL")
			r1, ok1 = recv1()
		default:
			st.onlyRight++
			err = report(r2.key, "NULL", r2.data)
			r2, ok2 = recv2()
		}
		if err != nil {
			return st, err
		}
	}
	return st, nil
}
