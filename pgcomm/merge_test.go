package main

import (
	"bytes"
	"testing"
)

func feed(rows ...row) <-chan row {
	ch := make(chan row, len(rows))
	for _, r := range rows {
		ch <- r
	}
	close(ch)
	return ch
}

func TestMergeIdentical(t *testing.T) {
	var buf bytes.Buffer
	st, err := merge(
		feed(row{1, "(a)"}, row{2, "(b)"}, row{3, "(c)"}),
		feed(row{1, "(a)"}, row{2, "(b)"}, row{3, "(c)"}),
		&buf)
	if err != nil {
		t.Fatal(err)
	}
	if st.diffs() != 0 || st.rows1 != 3 || st.rows2 != 3 {
		t.Fatalf("unexpected stats: %+v", st)
	}
	if buf.Len() != 0 {
		t.Fatalf("unexpected output: %q", buf.String())
	}
}

func TestMergeMismatch(t *testing.T) {
	var buf bytes.Buffer
	st, err := merge(
		feed(row{1, "(a)"}, row{2, "(b)"}, row{4, "(d)"}, row{5, "(e)"}),
		feed(row{1, "(a)"}, row{3, "(c)"}, row{4, "(D)"}, row{6, "(f)"}),
		&buf)
	if err != nil {
		t.Fatal(err)
	}
	want := stats{rows1: 4, rows2: 4, differ: 1, onlyLeft: 2, onlyRight: 2}
	if st != want {
		t.Fatalf("stats = %+v, want %+v", st, want)
	}
	wantOut := "2 (b) NULL\n" +
		"3 NULL (c)\n" +
		"4 (d) (D)\n" +
		"5 (e) NULL\n" +
		"6 NULL (f)\n"
	if buf.String() != wantOut {
		t.Fatalf("output:\n%s\nwant:\n%s", buf.String(), wantOut)
	}
}

func TestMergeOneSideEmpty(t *testing.T) {
	var buf bytes.Buffer
	st, err := merge(feed(), feed(row{7, "(x)"}), &buf)
	if err != nil {
		t.Fatal(err)
	}
	if st.onlyRight != 1 || st.rows1 != 0 || st.rows2 != 1 {
		t.Fatalf("unexpected stats: %+v", st)
	}
	if buf.String() != "7 NULL (x)\n" {
		t.Fatalf("unexpected output: %q", buf.String())
	}
}

func TestBuildQuery(t *testing.T) {
	p := &plan{pk: "id", cols: []string{"name", "Odd Col"}}
	got := buildQuery(`"public"."t"`, p, "id > 10")
	want := `SELECT "id", ROW("name", "Odd Col")::text FROM "public"."t" WHERE (id > 10) ORDER BY "id"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = buildQuery(`"public"."t"`, &plan{pk: "id"}, "")
	want = `SELECT "id", '()'::text FROM "public"."t" ORDER BY "id"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestNegotiate(t *testing.T) {
	ref := &description{side: "reference", schema: "public", name: "t",
		columns: []column{{"id", 23, "integer", ""}, {"a", 25, "text", "default"}, {"b", 1700, "numeric(10,2)", ""}},
	}
	ref.pk = []column{ref.columns[0]}
	tst := &description{side: "test", schema: "public", name: "t",
		columns: []column{{"b", 1700, "numeric(10,2)", ""}, {"id", 23, "integer", ""}, {"a", 25, "text", "default"}},
	}
	tst.pk = []column{tst.columns[1]}

	p, err := negotiate(ref, tst, nil)
	if err != nil {
		t.Fatal(err)
	}
	if p.pk != "id" || len(p.cols) != 2 || p.cols[0] != "a" || p.cols[1] != "b" {
		t.Fatalf("unexpected plan: %+v", p)
	}

	// Explicit column list, key included: key is dropped from the row.
	p, err = negotiate(ref, tst, []string{"id", "b"})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.cols) != 1 || p.cols[0] != "b" {
		t.Fatalf("unexpected plan: %+v", p)
	}

	// Type mismatch is an error.
	tst.columns[2].typeName = "varchar(10)"
	if _, err := negotiate(ref, tst, nil); err == nil {
		t.Fatal("expected a type mismatch error")
	}

	// Non-integer key is rejected.
	ref.pk = []column{{"id", 25, "text", "default"}}
	if _, err := negotiate(ref, tst, nil); err == nil {
		t.Fatal("expected a key type error")
	}
}
