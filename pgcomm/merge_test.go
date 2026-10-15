package main

import (
	"bytes"
	"errors"
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
	p := &plan{pk: "id", cols: []colPlan{
		{name: "name"},
		{name: "Odd Col", cast: [2]string{"", "numeric(12,3)"}},
	}}
	got := buildQuery(`"public"."t"`, p, 0, "id > 10")
	want := `SELECT "id", ROW("name", "Odd Col")::text FROM "public"."t" WHERE (id > 10) ORDER BY "id"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = buildQuery(`"public"."t"`, p, 1, "")
	want = `SELECT "id", ROW("name", "Odd Col"::numeric(12,3))::text FROM "public"."t" ORDER BY "id"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = buildQuery(`"public"."t"`, &plan{pk: "id"}, 0, "")
	want = `SELECT "id", '()'::text FROM "public"."t" ORDER BY "id"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

// fakeCommon stands in for the server: it knows one widening and nothing else.
func fakeCommon(c1, c2 column) (string, error) {
	if c1.typeName == "numeric(10,2)" && c2.typeName == "numeric(12,3)" {
		return "numeric(12,3)", nil
	}
	return "", errors.New("cannot be matched")
}

func TestNegotiate(t *testing.T) {
	ref := &description{side: "reference", schema: "public", name: "t",
		columns: []column{
			{name: "id", typeOID: 23, typmod: -1, typeName: "integer"},
			{name: "a", typeOID: 25, typmod: -1, typeName: "text"},
			{name: "b", typeOID: 1700, typmod: 10<<16 | 2 + 4, typeName: "numeric(10,2)"},
			{name: "only_ref", typeOID: 25, typmod: -1, typeName: "text"},
		},
	}
	ref.pk = []column{ref.columns[0]}
	tst := &description{side: "test", schema: "public", name: "t",
		columns: []column{
			{name: "only_test", typeOID: 25, typmod: -1, typeName: "text"},
			{name: "b", typeOID: 1700, typmod: 10<<16 | 2 + 4, typeName: "numeric(10,2)"},
			{name: "id", typeOID: 20, typmod: -1, typeName: "bigint"}, // other integer width is fine
			{name: "a", typeOID: 25, typmod: -1, typeName: "text"},
		},
	}
	tst.pk = []column{tst.columns[2]}

	// Default list: the columns present on both sides, others ignored.
	p, err := negotiate(ref, tst, nil, fakeCommon)
	if err != nil {
		t.Fatal(err)
	}
	if p.pk != "id" || len(p.cols) != 2 || p.cols[0].name != "a" || p.cols[1].name != "b" {
		t.Fatalf("unexpected plan: %+v", p)
	}
	if len(p.ignored) != 2 || p.ignored[0] != "reference.only_ref" || p.ignored[1] != "test.only_test" {
		t.Fatalf("unexpected ignored list: %v", p.ignored)
	}

	// Explicit column list, key included: key is dropped from the row.
	p, err = negotiate(ref, tst, []string{"id", "b"}, fakeCommon)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.cols) != 1 || p.cols[0].name != "b" {
		t.Fatalf("unexpected plan: %+v", p)
	}

	// An explicitly named column must exist on both sides.
	if _, err := negotiate(ref, tst, []string{"only_ref"}, fakeCommon); err == nil {
		t.Fatal("expected a missing column error")
	}

	// Differing types: the narrower side is cast to the common type.
	tst.columns[1].typeName = "numeric(12,3)"
	p, err = negotiate(ref, tst, nil, fakeCommon)
	if err != nil {
		t.Fatal(err)
	}
	if b := p.cols[1]; b.cast != [2]string{"numeric(12,3)", ""} {
		t.Fatalf("unexpected casts for b: %+v", b)
	}

	// No common type is an error.
	tst.columns[1].typeName = "varchar(10)"
	if _, err := negotiate(ref, tst, nil, fakeCommon); err == nil {
		t.Fatal("expected a no-common-type error")
	}

	// Non-integer key is rejected.
	ref.pk = []column{{name: "id", typeOID: 25, typmod: -1, typeName: "text"}}
	if _, err := negotiate(ref, tst, nil, fakeCommon); err == nil {
		t.Fatal("expected a key type error")
	}
}

func TestCheckEncodings(t *testing.T) {
	ok := [][2]string{{"UTF8", "UTF8"}, {"UTF8", "LATIN1"}, {"SQL_ASCII", "SQL_ASCII"}}
	bad := [][2]string{{"SQL_ASCII", "UTF8"}, {"LATIN1", "SQL_ASCII"}}
	for _, e := range ok {
		if err := checkEncodings(e[0], e[1]); err != nil {
			t.Errorf("%v: unexpected error: %v", e, err)
		}
	}
	for _, e := range bad {
		if err := checkEncodings(e[0], e[1]); err == nil {
			t.Errorf("%v: expected an error", e)
		}
	}
}

func TestMajorVersion(t *testing.T) {
	cases := map[string]string{
		"18.0 (Homebrew)": "18",
		"17.6":            "17",
		"19devel":         "19",
		"19beta1":         "19",
		"10.23":           "10",
		"9.6.24":          "9.6",
		"weird":           "weird",
	}
	for in, want := range cases {
		if got := majorVersion(in); got != want {
			t.Errorf("majorVersion(%q) = %q, want %q", in, got, want)
		}
	}
	if w := versionWarning("18.0", "18.3 (Debian)"); w != "" {
		t.Errorf("same major: unexpected warning %q", w)
	}
	if w := versionWarning("17.6", "18.0"); w == "" {
		t.Error("different majors: expected a warning")
	}
}

func TestWiderTypmod(t *testing.T) {
	num := func(p, s int32) int32 { return (p<<16 | s&0x7ff) + 4 }
	cases := []struct {
		name string
		oid  uint32
		a, b int32
		want int32
	}{
		{"numeric same scale", numericOID, num(10, 2), num(12, 2), num(12, 2)},
		{"numeric wider scale", numericOID, num(10, 2), num(10, 3), num(11, 3)},
		{"numeric negative scale", numericOID, num(5, -2), num(4, 1), num(8, 1)},
		{"numeric unconstrained wins", numericOID, num(10, 2), -1, -1},
		{"varchar length", 1043, 10 + 4, 20 + 4, 20 + 4},
		{"timestamp precision", 1114, 3, 6, 6},
	}
	for _, c := range cases {
		if got := widerTypmod(c.oid, c.a, c.b); got != c.want {
			t.Errorf("%s: got %d, want %d", c.name, got, c.want)
		}
	}
}
