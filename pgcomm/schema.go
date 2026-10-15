package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Session settings that affect the text output of values or name
// resolution. They must be identical on both sides, otherwise equal rows
// would serialise differently or names would resolve to different objects.
//
// search_path is "public" rather than the default "$user", public: $user
// expands to the role name, which may differ between the two instances.
// pg_catalog is still searched first implicitly.
const sessionSetup = `
SET search_path = public;
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, YMD';
SET IntervalStyle = 'postgres';
SET bytea_output = 'hex';
SET extra_float_digits = 3;
SET lc_monetary = 'C';
SET quote_all_identifiers = on;
SET client_encoding = 'UTF8';
SET statement_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
`

const numericOID = 1700

// Integer types accepted as a primary key: int2, int4, int8. The key is
// read into int64, so the two sides may use different integer widths.
var integerTypes = map[uint32]bool{21: true, 23: true, 20: true}

type side struct {
	name     string
	conn     *pgx.Conn
	tx       pgx.Tx
	encoding string // server_encoding of the connected database
	version  string // server_version, e.g. "18.0 (Homebrew)"
}

// majorVersion extracts the major version from server_version:
// "18.0 (Homebrew)" -> "18", "19devel" -> "19", "9.6.24" -> "9.6".
func majorVersion(v string) string {
	end := 0
	for end < len(v) && (v[end] == '.' || v[end] >= '0' && v[end] <= '9') {
		end++
	}
	parts := strings.Split(v[:end], ".")
	if parts[0] == "" {
		return v
	}
	if len(parts[0]) == 1 && len(parts) > 1 { // before 10, the major was "X.Y"
		return parts[0] + "." + parts[1]
	}
	return parts[0]
}

// versionWarning returns a warning if the servers run different major
// versions, or "" otherwise. Output functions sometimes change between
// major versions (float8 is printed differently before and after PG 12),
// so mismatches may come from the servers rather than from the data.
func versionWarning(ref, test string) string {
	m1, m2 := majorVersion(ref), majorVersion(test)
	if m1 == m2 {
		return ""
	}
	return fmt.Sprintf("warning: different major versions: %s (reference) vs %s (test); "+
		"value output may differ between versions and show up as mismatches", m1, m2)
}

// checkEncodings refuses to compare an SQL_ASCII database with a database
// in any other encoding. An SQL_ASCII server does no conversion to
// client_encoding and returns raw bytes, while any other server converts to
// UTF8, so equal text could arrive as different bytes. Two SQL_ASCII
// databases are fine: both return raw bytes.
func checkEncodings(ref, test string) error {
	if (ref == "SQL_ASCII") != (test == "SQL_ASCII") {
		return fmt.Errorf("server encodings are incompatible: %s (reference) vs %s (test); "+
			"SQL_ASCII must be on both sides or on neither", ref, test)
	}
	return nil
}

type column struct {
	name     string
	typeOID  uint32
	typmod   int32
	typeName string // format_type(atttypid, atttypmod)
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

// colPlan is one compared column. cast[i] is the type the column is cast
// to on side i (0 = reference, 1 = test), or "" when no cast is needed.
type colPlan struct {
	name string
	cast [2]string
}

// plan is the negotiated result: which key and which columns are compared.
type plan struct {
	pk      string
	pkType  string
	cols    []colPlan // non-key columns, in reference-table order
	ignored []string  // columns present on one side only (default column list)
}

// commonTypeFunc returns the most general type of two column definitions,
// as a format_type string, or an error if there is none.
type commonTypeFunc func(c1, c2 column) (string, error)

// openSide connects, applies the session settings and opens a read-only
// REPEATABLE READ transaction. A non-empty snapshot is an exported snapshot
// id: the transaction then sees exactly what the exporting one sees.
func openSide(ctx context.Context, name, dsn, snapshot string) (*side, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("%s: connect: %w", name, err)
	}
	// The server reports these at startup; no query needed.
	s := &side{
		name:     name,
		conn:     conn,
		encoding: conn.PgConn().ParameterStatus("server_encoding"),
		version:  conn.PgConn().ParameterStatus("server_version"),
	}
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
	if snapshot != "" {
		sql := "SET TRANSACTION SNAPSHOT '" + strings.ReplaceAll(snapshot, "'", "''") + "'"
		if _, err := tx.Exec(ctx, sql); err != nil {
			s.close()
			return nil, fmt.Errorf("%s: import snapshot: %w", name, err)
		}
	}
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
	switch relkind {
	case "r":
	case "p":
		return nil, fmt.Errorf("%s: %s is a partitioned table; not supported yet", s.name, d.qualifiedName())
	default:
		return nil, fmt.Errorf("%s: %s is not a table (relkind %q)", s.name, d.qualifiedName(), relkind)
	}

	rows, err := s.tx.Query(ctx, `
		SELECT a.attname, a.atttypid, a.atttypmod,
		       pg_catalog.format_type(a.atttypid, a.atttypmod)
		FROM pg_catalog.pg_attribute a
		WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, d.oid)
	if err != nil {
		return nil, fmt.Errorf("%s: columns of %s: %w", s.name, d.qualifiedName(), err)
	}
	d.columns, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (column, error) {
		var c column
		err := r.Scan(&c.name, &c.typeOID, &c.typmod, &c.typeName)
		return c, err
	})
	if err != nil {
		return nil, fmt.Errorf("%s: columns of %s: %w", s.name, d.qualifiedName(), err)
	}

	// Only the first indnkeyatts entries of indkey are key columns; the rest
	// are INCLUDE columns, which are not part of the key.
	rows, err = s.tx.Query(ctx, `
		SELECT a.attname
		FROM pg_catalog.pg_index i
		JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid
		WHERE i.indrelid = $1 AND i.indisprimary
		  AND a.attnum = ANY ((i.indkey::int2[])[0:i.indnkeyatts - 1])
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

// commonType asks this server for the most general type of two column
// definitions.
//
// Same base type: the wider type modifier wins (varchar(10) vs varchar(20)
// gives varchar(20), numeric(10,2) vs numeric(12,3) gives numeric(12,3)).
//
// Different base types: PostgreSQL picks the type exactly as it does for
// UNION (int4 vs int8 gives int8, timestamp vs timestamptz gives
// timestamptz); no such type means there is no unambiguous mapping. If the
// winner is one side's own type, that side's full definition is kept, so
// int4 vs numeric(10,2) compares as numeric(10,2) on both sides.
func (s *side) commonType(ctx context.Context, c1, c2 column) (string, error) {
	if c1.typeOID == c2.typeOID {
		return s.formatType(ctx, c1.typeOID, widerTypmod(c1.typeOID, c1.typmod, c2.typmod))
	}

	// The probe may fail ("UNION types ... cannot be matched"); run it under
	// a savepoint so that the failure does not abort the whole transaction.
	sp, err := s.tx.Begin(ctx)
	if err != nil {
		return "", err
	}
	var oid uint32
	err = sp.QueryRow(ctx, fmt.Sprintf(
		"SELECT pg_catalog.pg_typeof(x)::oid FROM (SELECT NULL::%s UNION ALL SELECT NULL::%s) s(x) LIMIT 1",
		c1.typeName, c2.typeName)).Scan(&oid)
	if err != nil {
		_ = sp.Rollback(ctx)
		return "", err
	}
	if err := sp.Commit(ctx); err != nil {
		return "", err
	}

	switch oid {
	case c1.typeOID:
		return c1.typeName, nil
	case c2.typeOID:
		return c2.typeName, nil
	}
	return s.formatType(ctx, oid, -1)
}

func (s *side) formatType(ctx context.Context, oid uint32, typmod int32) (string, error) {
	var name string
	err := s.tx.QueryRow(ctx, "SELECT pg_catalog.format_type($1, $2)", oid, typmod).Scan(&name)
	return name, err
}

// widerTypmod returns the type modifier that can hold values of both.
// -1 means "no modifier" and always wins. For numeric the modifier packs
// precision and scale, so both are widened; for the other types with a
// modifier (char/varchar length, time/timestamp precision, bit length) the
// larger number is the wider one.
func widerTypmod(typeOID uint32, a, b int32) int32 {
	if a == -1 || b == -1 {
		return -1
	}
	if typeOID != numericOID {
		return max(a, b)
	}
	p1, s1 := numericPS(a)
	p2, s2 := numericPS(b)
	scale := max(s1, s2)
	precision := max(p1-s1, p2-s2) + scale
	if precision < 1 || precision > 1000 {
		return -1
	}
	return (precision<<16 | scale&0x7ff) + 4
}

// numericPS decodes a numeric typmod: ((precision << 16) | scale) + 4, where
// the scale is an 11-bit signed number (negative scales exist since PG 15).
func numericPS(typmod int32) (precision, scale int32) {
	t := typmod - 4
	return (t >> 16) & 0xffff, ((t & 0x7ff) ^ 1024) - 1024
}

// negotiate checks that both descriptions agree on the primary key and maps
// every compared column to a common type.
//
// With no explicit column list, exactly the columns present on both sides
// are compared; a column present on one side only is ignored. A column
// named explicitly must exist on both sides.
func negotiate(d1, d2 *description, requested []string, common commonTypeFunc) (*plan, error) {
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

	p := &plan{pk: pk1.name, pkType: pk1.typeName}

	if len(requested) == 0 {
		for _, c := range d1.columns {
			if _, ok := d2.column(c.name); ok {
				requested = append(requested, c.name)
			} else {
				p.ignored = append(p.ignored, "reference."+c.name)
			}
		}
		for _, c := range d2.columns {
			if _, ok := d1.column(c.name); !ok {
				p.ignored = append(p.ignored, "test."+c.name)
			}
		}
	}

	var problems []string
	seen := map[string]bool{}
	for _, name := range requested {
		if seen[name] || name == p.pk {
			continue
		}
		seen[name] = true
		c1, ok1 := d1.column(name)
		c2, ok2 := d2.column(name)
		switch {
		case !ok1 && !ok2:
			problems = append(problems, fmt.Sprintf("column %q exists on neither side", name))
			continue
		case !ok1:
			problems = append(problems, fmt.Sprintf("column %q is missing on the reference side", name))
			continue
		case !ok2:
			problems = append(problems, fmt.Sprintf("column %q is missing on the test side", name))
			continue
		}

		cp := colPlan{name: name}
		if c1.typeName != c2.typeName {
			target, err := common(c1, c2)
			if err != nil {
				problems = append(problems, fmt.Sprintf("column %q: no common type for %s (reference) and %s (test): %v",
					name, c1.typeName, c2.typeName, err))
				continue
			}
			if c1.typeName != target {
				cp.cast[0] = target
			}
			if c2.typeName != target {
				cp.cast[1] = target
			}
		}
		p.cols = append(p.cols, cp)
	}
	if len(problems) > 0 {
		return nil, fmt.Errorf("table structures do not match:\n  %s", strings.Join(problems, "\n  "))
	}
	return p, nil
}

// buildQuery produces the SELECT for one side (0 = reference, 1 = test):
// the key and the server-side text form of the row, ordered by the key.
// The row is ROW(c1, c2, ...)::text, i.e. record_out, which is exactly what
// psql shows for a composite value. Columns whose types differ between the
// sides are cast to their common type first. r restricts the key range.
func buildQuery(qualifiedTable string, p *plan, side int, filter string, r keyRange) string {
	pk := pgx.Identifier{p.pk}.Sanitize()
	rowExpr := "'()'::text"
	if len(p.cols) > 0 {
		exprs := make([]string, len(p.cols))
		for i, c := range p.cols {
			exprs[i] = pgx.Identifier{c.name}.Sanitize()
			if t := c.cast[side]; t != "" {
				exprs[i] += "::" + t
			}
		}
		rowExpr = "ROW(" + strings.Join(exprs, ", ") + ")::text"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "SELECT %s, %s FROM %s", pk, rowExpr, qualifiedTable)
	var conds []string
	if f := strings.TrimSpace(filter); f != "" {
		conds = append(conds, "("+f+")")
	}
	if c := r.condition(pk); c != "" {
		conds = append(conds, c)
	}
	if len(conds) > 0 {
		fmt.Fprintf(&b, " WHERE %s", strings.Join(conds, " AND "))
	}
	fmt.Fprintf(&b, " ORDER BY %s", pk)
	return b.String()
}
