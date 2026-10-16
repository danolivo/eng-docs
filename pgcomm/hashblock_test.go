package main

import (
	"bytes"
	"testing"
)

func TestBlockMatch(t *testing.T) {
	b := newBlock(1 << 20)
	for _, r := range []refRow{{"(a)", "(1)"}, {"(b)", "(2)"}, {"(c)", "(3)"}, {"(d)", "(4)"}} {
		if err := b.add(r.key, r.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := b.add("(b)", "(x)"); err == nil {
		t.Fatal("expected a duplicate key error")
	}

	var buf bytes.Buffer
	var st stats
	for _, r := range []refRow{{"(a)", "(1)"}, {"(a0)", "(9)"}, {"(c)", "(C)"}} {
		if err := b.probe(r.key, r.data, &buf, &st); err != nil {
			t.Fatal(err)
		}
	}
	if err := b.probe("(c)", "(3)", &buf, &st); err == nil {
		t.Fatal("expected a duplicate key error on the test side")
	}
	if err := b.finish(&buf, &st); err != nil {
		t.Fatal(err)
	}
	want := "(a0) NULL (9)\n" +
		"(c) (3) (C)\n" +
		"(b) (2) NULL\n" +
		"(d) (4) NULL\n"
	if buf.String() != want {
		t.Fatalf("output:\n%s\nwant:\n%s", buf.String(), want)
	}
	if (st != stats{differ: 1, onlyLeft: 2, onlyRight: 1}) {
		t.Fatalf("unexpected stats: %+v", st)
	}

	// A reset block is empty and reusable.
	b.reset()
	if len(b.rows) != 0 || len(b.index) != 0 || b.size != 0 {
		t.Fatalf("block not reset: %+v", b)
	}
	if err := b.add("(b)", "(2)"); err != nil {
		t.Fatal(err)
	}
}

func TestBlockFull(t *testing.T) {
	b := newBlock(1)
	if b.full() {
		t.Fatal("an empty block is never full")
	}
	_ = b.add("(k)", "(a very long row that alone exceeds the limit)")
	if !b.full() {
		t.Fatal("a block over its limit must be full")
	}
	b = newBlock(10 * rowOverhead)
	for i := 0; !b.full(); i++ {
		_ = b.add(string(rune('a'+i)), "")
	}
	if n := len(b.rows); n != 10 {
		t.Fatalf("block took %d rows, want 10", n)
	}
}

func TestHashQueries(t *testing.T) {
	p := &plan{
		key: []keyCol{
			{colPlan: colPlan{name: "id", cast: [2]string{"bigint", ""}}, base: [2]string{"integer", "bigint"}},
			{colPlan: colPlan{name: "Name"}, base: [2]string{"character varying", "text"}},
		},
		cols: []colPlan{{name: "v"}},
	}
	h := &hashStrategy{tables: [2]string{`"public"."r"`, `"public"."t"`}, p: p, filter: "v <> ''"}

	got := h.refQuery()
	want := `SELECT ROW("id"::bigint, "Name")::text, "id"::text, "Name"::text, ROW("v")::text FROM "public"."r"` +
		` WHERE (v <> '') ORDER BY "public"."r"."id", "public"."r"."Name"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = h.testQuery(true, true)
	want = `SELECT ROW("id", "Name")::text, ROW("v")::text FROM "public"."t"` +
		` WHERE (v <> '') AND ("id", "Name") > ($1::bigint, $2::text) AND ("id", "Name") <= ($3::bigint, $4::text)` +
		` ORDER BY "public"."t"."id", "public"."t"."Name"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = h.testQuery(false, true)
	want = `SELECT ROW("id", "Name")::text, ROW("v")::text FROM "public"."t"` +
		` WHERE (v <> '') AND ("id", "Name") <= ($1::bigint, $2::text) ORDER BY "public"."t"."id", "public"."t"."Name"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}

	// Single-column key: a plain comparison; no filter, no WHERE.
	h = &hashStrategy{tables: [2]string{`"r"`, `"t"`}, p: &plan{
		key: []keyCol{{colPlan: colPlan{name: "k"}, base: [2]string{"uuid", "uuid"}}},
	}}
	got = h.testQuery(true, false)
	want = `SELECT ROW("k")::text, '()'::text FROM "t" WHERE "k" > $1::uuid ORDER BY "t"."k"`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if got, want := h.query(1), `SELECT ROW("k")::text, '()'::text FROM "t" ORDER BY "t"."k"`; got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestByteSize(t *testing.T) {
	ok := map[string]int64{
		"256":   256 << 20,
		"1":     1 << 20,
		"8kB":   8 << 10,
		"64 MB": 64 << 20,
		"2GB":   2 << 30,
		"1TB":   1 << 40,
	}
	for in, want := range ok {
		var b byteSize
		if err := b.Set(in); err != nil || int64(b) != want {
			t.Errorf("%q: got %d, %v; want %d", in, int64(b), err, want)
		}
	}
	for _, in := range []string{"", "0", "-1", "1.5MB", "10kb", "MB", "8 bytes", "99999999999TB"} {
		var b byteSize
		if err := b.Set(in); err == nil {
			t.Errorf("%q: expected an error", in)
		}
	}
	for b, want := range map[byteSize]string{256 << 20: "256MB", 8 << 10: "8kB", 1536: "1536B", 3 << 30: "3GB", 1 << 40: "1TB"} {
		if got := b.String(); got != want {
			t.Errorf("String(%d) = %q, want %q", int64(b), got, want)
		}
	}
}
