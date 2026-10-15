package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Session settings that affect the text output of values. They must be
// identical on both sides, otherwise equal rows would serialise differently.
const sessionSetup = `
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, YMD';
SET IntervalStyle = 'postgres';
SET bytea_output = 'hex';
SET extra_float_digits = 3;
SET quote_all_identifiers = on;
SET client_encoding = 'UTF8';
SET statement_timeout = 0;
`

// Integer types accepted as a primary key: int2, int4, int8.
var integerTypes = map[uint32]bool{21: true, 23: true, 20: true}

type side struct {
	name string
	conn *pgx.Conn
	tx   pgx.Tx
}

type column struct {
	name      string
	typeOID   uint32
	typeName  string // format_type(atttypid, atttypmod)
	collation string // "" when the type is not collatable
}

// description is what one side knows about the table.
type description struct {
	side    string
	oid     uint32
	schema  string
	name    string
	columns []column
	pk      []column
}

func (d *description) qualifiedName() string {
	return pgx.Identifier{d.schema, d.name}.Sanitize()
}

func (d *description) column(name string) (column, bool) {
	for _, c := range d.columns {
		if c.name == name {
			return c, true
		}
	}
	return column{}, false
}

// plan is the negotiated result: which key and which columns are compared.
type plan struct {
	pk     string
	pkType string
	cols   []string // non-key columns, in reference-table order
}

func openSide(ctx context.Context, name, dsn string) (*side, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("%s: connect: %w", name, err)
	}
	s := &side{name: name, conn: conn}
	// Simple protocol on purpose: several statements in one round trip.
	if _, err := conn.PgConn().Exec(ctx, sessionSetup).ReadAll(); err != nil {
		s.close()
		return nil, fmt.Errorf("%s: session setup: %w", name, err)
	}
	// One snapshot per side for the whole run: catalog lookups and the data
	// stream see the same state. REPEATABLE READ also allows exporting the
	// snapshot later, for parallel range workers.
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		s.close()
		return nil, fmt.Errorf("%s: begin: %w", name, err)
	}
	s.tx = tx
	return s, nil
}

func (s *side) close() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if s.tx != nil {
		_ = s.tx.Rollback(ctx)
	}
	_ = s.conn.Close(ctx)
}

// pinSearchPath restricts name resolution to pg_catalog and the schema of
// the compared table, so that a filter expression means the same on both
// sides regardless of per-role or per-database search_path settings.
func (s *side) pinSearchPath(ctx context.Context, schema string) error {
	sql := "SET search_path = pg_catalog, " + pgx.Identifier{schema}.Sanitize()
	if _, err := s.tx.Exec(ctx, sql); err != nil {
		return fmt.Errorf("%s: %s: %w", s.name, sql, err)
	}
	return nil
}

func (s *side) describe(ctx context.Context, table string) (*description, error) {
	d := &description{side: s.name}

	var relkind string
	err := s.tx.QueryRow(ctx, `
		SELECT c.oid, n.nspname, c.relname, c.relkind::text
		FROM pg_catalog.pg_class c
		JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
		WHERE c.oid = pg_catalog.to_regclass($1)`, table).
		Scan(&d.oid, &d.schema, &d.name, &relkind)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%s: relation %q does not exist", s.name, table)
	}
	if err != nil {
		return nil, fmt.Errorf("%s: resolve %q: %w", s.name, table, err)
	}
	if relkind != "r" && relkind != "p" {
		return nil, fmt.Errorf("%s: %s is not a table (relkind %q)", s.name, d.qualifiedName(), relkind)
	}

	rows, err := s.tx.Query(ctx, `
		SELECT a.attname, a.atttypid, pg_catalog.format_type(a.atttypid, a.atttypmod),
		       COALESCE(co.collname, '')
		FROM pg_catalog.pg_attribute a
		LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
		WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, d.oid)
	if err != nil {
		return nil, fmt.Errorf("%s: columns of %s: %w", s.name, d.qualifiedName(), err)
	}
	d.columns, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (column, error) {
		var c column
		err := r.Scan(&c.name, &c.typeOID, &c.typeName, &c.collation)
		return c, err
	})
	if err != nil {
		return nil, fmt.Errorf("%s: columns of %s: %w", s.name, d.qualifiedName(), err)
	}

	rows, err = s.tx.Query(ctx, `
		SELECT a.attname
		FROM pg_catalog.pg_index i
		JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		WHERE i.indrelid = $1 AND i.indisprimary
		ORDER BY pg_catalog.array_position(i.indkey::int2[], a.attnum)`, d.oid)
	if err != nil {
		return nil, fmt.Errorf("%s: primary key of %s: %w", s.name, d.qualifiedName(), err)
	}
	pkNames, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("%s: primary key of %s: %w", s.name, d.qualifiedName(), err)
	}
	for _, n := range pkNames {
		c, ok := d.column(n)
		if !ok {
			return nil, fmt.Errorf("%s: primary key column %q not found among attributes", s.name, n)
		}
		d.pk = append(d.pk, c)
	}
	return d, nil
}

// negotiate checks that both descriptions agree on the primary key and on
// every compared column. Any disagreement is an error: this version does
// not try to find a "most general" type.
func negotiate(d1, d2 *description, requested []string) (*plan, error) {
	for _, d := range []*description{d1, d2} {
		switch {
		case len(d.pk) == 0:
			return nil, fmt.Errorf("%s: %s has no primary key", d.side, d.qualifiedName())
		case len(d.pk) > 1:
			return nil, fmt.Errorf("%s: %s has a composite primary key; only single-column integer keys are supported", d.side, d.qualifiedName())
		case !integerTypes[d.pk[0].typeOID]:
			return nil, fmt.Errorf("%s: primary key %s.%s is %s; only int2/int4/int8 keys are supported",
				d.side, d.qualifiedName(), d.pk[0].name, d.pk[0].typeName)
		}
	}
	pk1, pk2 := d1.pk[0], d2.pk[0]
	if pk1.name != pk2.name {
		return nil, fmt.Errorf("primary key column differs: %q (reference) vs %q (test)", pk1.name, pk2.name)
	}
	if pk1.typeName != pk2.typeName {
		return nil, fmt.Errorf("primary key type differs: %s (reference) vs %s (test)", pk1.typeName, pk2.typeName)
	}
	if pk1.collation != pk2.collation {
		return nil, fmt.Errorf("primary key collation differs: %q (reference) vs %q (test)", pk1.collation, pk2.collation)
	}

	p := &plan{pk: pk1.name, pkType: pk1.typeName}

	if len(requested) == 0 {
		for _, c := range d1.columns {
			requested = append(requested, c.name)
		}
	}
	var problems []string
	seen := map[string]bool{}
	for _, name := range requested {
		if seen[name] {
			continue
		}
		seen[name] = true
		if name == p.pk {
			continue
		}
		c1, ok1 := d1.column(name)
		c2, ok2 := d2.column(name)
		switch {
		case !ok1 && !ok2:
			problems = append(problems, fmt.Sprintf("column %q exists on neither side", name))
		case !ok1:
			problems = append(problems, fmt.Sprintf("column %q is missing on the reference side", name))
		case !ok2:
			problems = append(problems, fmt.Sprintf("column %q is missing on the test side", name))
		case c1.typeName != c2.typeName:
			problems = append(problems, fmt.Sprintf("column %q: %s (reference) vs %s (test)", name, c1.typeName, c2.typeName))
		default:
			p.cols = append(p.cols, name)
		}
	}
	if len(problems) > 0 {
		return nil, fmt.Errorf("table structures do not match:\n  %s", strings.Join(problems, "\n  "))
	}
	return p, nil
}

// buildQuery produces the per-side SELECT: the key and the server-side text
// form of the row, ordered by the key. The row is ROW(c1, c2, ...)::text,
// i.e. record_out, which is exactly what psql shows for a composite value.
func buildQuery(qualifiedTable string, p *plan, filter string) string {
	pk := pgx.Identifier{p.pk}.Sanitize()
	rowExpr := "'()'::text"
	if len(p.cols) > 0 {
		quoted := make([]string, len(p.cols))
		for i, c := range p.cols {
			quoted[i] = pgx.Identifier{c}.Sanitize()
		}
		rowExpr = "ROW(" + strings.Join(quoted, ", ") + ")::text"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "SELECT %s, %s FROM %s", pk, rowExpr, qualifiedTable)
	if f := strings.TrimSpace(filter); f != "" {
		fmt.Fprintf(&b, " WHERE (%s)", f)
	}
	fmt.Fprintf(&b, " ORDER BY %s", pk)
	return b.String()
}
