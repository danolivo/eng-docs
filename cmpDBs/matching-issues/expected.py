#!/usr/bin/env python3
r"""Compute the expected result of a comparison of two loaded databases.

Usage: ./expected.py <database of node 1> <database of node 2> > expected.csv
       ./expected.py <database of node 1> <database of node 2> --check expected.csv

The connection comes from the usual PG* variables. Both databases must be in
one instance, and the role must be a superuser.

For each table of the register (ref_meta.cases) the script prints one line:
the kind of the relation on each node, the key, the row counts, and the number
of rows that a correct comparison reports under two rules.

Text rule:     a value is the text output of its type under the session
               settings below; rows are paired by the text of the key; two
               values are equal when the texts are byte-equal.
Operator rule: rows are paired by the operator = of the key type; two values
               differ when IS DISTINCT FROM says so.

A table without a primary key is compared as a set of whole rows with their
counts; "changed" has no meaning there. An empty field means that the number
cannot be computed; the column "notes" says why.
"""
import csv
import json
import os
import subprocess
import sys
from collections import Counter

SETTINGS = ('-c client_encoding=UTF8 -c TimeZone=UTC -c DateStyle=ISO,MDY '
            '-c IntervalStyle=postgres -c extra_float_digits=1 '
            '-c bytea_output=hex -c lc_monetary=C -c client_min_messages=error')
FIELDS = ['table', 'kind_n1', 'kind_n2', 'key', 'rows_n1', 'rows_n2',
          'text_only_n1', 'text_only_n2', 'text_changed',
          'eq_only_n1', 'eq_only_n2', 'eq_changed', 'notes']
KINDS = {'r': 'table', 'p': 'partitioned table', 'v': 'view',
         'm': 'materialized view', 'f': 'foreign table'}


def psql(db, sql):
    """Run a script; return (list of output lines, first line of the error)."""
    p = subprocess.run(['psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', '-'],
                       input=sql, capture_output=True, text=True,
                       env=dict(os.environ, PGOPTIONS=SETTINGS))
    err = p.stderr.strip().splitlines()
    return p.stdout.splitlines(), (err[0].split('ERROR:')[-1].strip() if p.returncode else '')


def q(name):
    return '"' + name.replace('"', '""') + '"'


def lit(value):
    return "'" + value.replace("'", "''") + "'"


def split_name(tbl):
    """Split schema.table; each part can be a quoted identifier."""
    quoted = False
    for i, ch in enumerate(tbl):
        if ch == '"':
            quoted = not quoted
        elif ch == '.' and not quoted:
            return tbl[:i], tbl[i + 1:]
    sys.exit('not a qualified name: ' + tbl)


def describe(db):
    """Kind, columns and primary key of every table of the register."""
    out, err = psql(db, r"""
SELECT json_build_object('tbl', r.tbl, 'kind', c.relkind,
  'cols', (SELECT json_agg(json_build_array(a.attname, format_type(a.atttypid, a.atttypmod)) ORDER BY a.attnum)
             FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
  'key', (SELECT json_agg(a.attname ORDER BY k.ord)
            FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
           WHERE i.indrelid = c.oid AND i.indisprimary))
  FROM (SELECT DISTINCT tbl FROM ref_meta.cases WHERE tbl NOT LIKE 'pg\_catalog.%') r
  LEFT JOIN pg_class c ON c.oid = to_regclass(r.tbl);
""")
    if err:
        sys.exit('%s: %s' % (db, err))
    return {d['tbl']: d for d in map(json.loads, out)}


def read_rows(db, tbl, cols):
    """All rows as tuples of texts (None for NULL), by the text rule.

    num_nulls() tests the value itself: "IS NULL" is also true for a
    composite value whose fields are all NULL, such as (,).
    """
    items = ', '.join('CASE WHEN num_nulls(%s) = 1 THEN NULL ELSE format(\'%%s\', %s) END' % (q(c), q(c)) for c in cols)
    out, err = psql(db, 'SELECT array_to_json(ARRAY[%s]::text[]) FROM %s;' % (items, tbl))
    return [tuple(json.loads(line)) for line in out], err


def text_rule(rows1, rows2, nkey):
    if nkey == 0:
        c1, c2 = Counter(rows1), Counter(rows2)   # whole rows with their counts
        return sum((c1 - c2).values()), sum((c2 - c1).values()), ''
    d1 = {r[:nkey]: r[nkey:] for r in rows1}
    d2 = {r[:nkey]: r[nkey:] for r in rows2}
    if len(d1) != len(rows1) or len(d2) != len(rows2):
        return None
    return (len(d1.keys() - d2.keys()), len(d2.keys() - d1.keys()),
            sum(1 for k in d1.keys() & d2.keys() if d1[k] != d2[k]))


def operator_rule(db1, db2, tbl, key, cols):
    """Counts by = and IS DISTINCT FROM, through a foreign table in a
    transaction that is rolled back."""
    schema, name = [p[1:-1].replace('""', '"') if p.startswith('"') else p for p in split_name(tbl)]
    head = r"""
BEGIN;
CREATE SCHEMA expected_tmp;
DO $$ BEGIN
  EXECUTE format('CREATE SERVER expected_tmp_n2 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %%L, port %%L, dbname %%L)',
                 %s, current_setting('port'), %s);
  EXECUTE 'CREATE USER MAPPING FOR CURRENT_USER SERVER expected_tmp_n2';
END $$;
IMPORT FOREIGN SCHEMA %s LIMIT TO (%s) FROM SERVER expected_tmp_n2 INTO expected_tmp;
""" % (lit(os.environ.get('PGHOST', 'localhost')), lit(db2), q(schema), q(name))
    join = ' AND '.join('l.%s = r.%s' % (q(k), q(k)) for k in key)
    src = '%s l FULL JOIN expected_tmp.%s r ON %s' % (tbl, q(name), join)
    notes = []
    out, err = psql(db1, head + 'SELECT 1 FROM %s LIMIT 0; ROLLBACK;' % src)
    if err:
        return '', '', '', ['operator rule not computed: ' + err]
    def differ(columns):
        return ' OR '.join('l.%s IS DISTINCT FROM r.%s' % (q(c), q(c)) for c in columns) or 'false'

    usable = cols
    out, err = psql(db1, head + 'SELECT %s FROM %s LIMIT 0; ROLLBACK;' % (differ(cols), src))
    if err:                       # find the columns that cannot be compared
        usable = []
        for c in cols:
            out, err = psql(db1, head + 'SELECT %s FROM %s LIMIT 0; ROLLBACK;' % (differ([c]), src))
            if err:
                notes.append('no operator = for the column %s' % c)
            else:
                usable.append(c)
    k = q(key[0])
    out, err = psql(db1, head + """
SELECT count(*) FILTER (WHERE r.%s IS NULL), count(*) FILTER (WHERE l.%s IS NULL),
       count(*) FILTER (WHERE l.%s IS NOT NULL AND r.%s IS NOT NULL AND (%s))
  FROM %s;
ROLLBACK;""" % (k, k, k, k, differ(usable), src))
    if err:
        return '', '', '', ['operator rule not computed: ' + err]
    a, b, c = out[-1].split('|')
    return a, b, c, notes


def compute(db1, db2):
    d1, d2 = describe(db1), describe(db2)
    result = []
    for tbl in sorted(d1):
        a, b = d1[tbl], d2.get(tbl) or {'kind': None, 'cols': None, 'key': None}
        row = dict.fromkeys(FIELDS, '')
        row['table'] = tbl
        row['kind_n1'] = KINDS.get(a['kind'], 'missing')
        row['kind_n2'] = KINDS.get(b['kind'], 'missing')
        notes = []
        if not a['kind'] or not b['kind']:
            row['notes'] = 'the relation is missing on one node'
            result.append(row)
            continue
        c1, c2 = dict(map(tuple, a['cols'] or [])), dict(map(tuple, b['cols'] or []))
        key = a['key'] or []
        if (a['key'] or []) != (b['key'] or []):
            notes.append('primary key differs: (%s) / (%s)' % (', '.join(a['key'] or []), ', '.join(b['key'] or [])))
            key = key if all(k in c2 for k in key) else []
        if not key:
            notes.append('no common primary key: whole rows are compared as a set with counts')
        for c in c1:
            if c not in c2:
                notes.append('column %s only on n1' % c)
            elif c1[c] != c2[c]:
                notes.append('type of %s differs: %s / %s' % (c, c1[c], c2[c]))
        notes += ['column %s only on n2' % c for c in c2 if c not in c1]
        if [c for c in c1 if c in c2] != [c for c in c2 if c in c1]:
            notes.append('column order differs')
        others = [c for c in c1 if c in c2 and c not in key]
        row['key'] = ', '.join(key)
        r1, e1 = read_rows(db1, tbl, key + others)
        r2, e2 = read_rows(db2, tbl, key + others)
        if e1 or e2:
            notes += ['read error on n1: ' + e1] * bool(e1) + ['read error on n2: ' + e2] * bool(e2)
        else:
            row['rows_n1'], row['rows_n2'] = len(r1), len(r2)
            counts = text_rule(r1, r2, len(key))
            if counts is None:
                notes.append('the key (%s) is not unique on one node: whole rows are compared as a set with counts' % ', '.join(key))
                counts, key = text_rule(r1, r2, 0), []
            row['text_only_n1'], row['text_only_n2'], row['text_changed'] = counts
            row['key'] = ', '.join(key)
            if key:
                (row['eq_only_n1'], row['eq_only_n2'], row['eq_changed'], more) = operator_rule(db1, db2, tbl, key, others)
                notes += more
        row['notes'] = '; '.join(notes)
        result.append(row)
    return result


def main():
    if len(sys.argv) not in (3, 5) or (len(sys.argv) == 5 and sys.argv[3] != '--check'):
        sys.exit(__doc__)
    rows = compute(sys.argv[1], sys.argv[2])
    if len(sys.argv) == 3:
        w = csv.DictWriter(sys.stdout, FIELDS, lineterminator='\n')
        w.writeheader()
        w.writerows(rows)
        return
    with open(sys.argv[4], newline='', encoding='utf-8') as f:
        old = {r['table']: r for r in csv.DictReader(f)}
    bad = 0
    for r in rows:
        new = {k: str(v) for k, v in r.items()}
        if old.get(r['table']) != new:
            bad += 1
            print('differs: %s\n  file: %s\n  now:  %s' % (r['table'], old.get(r['table']), new))
    print('%d tables, %d differ from %s' % (len(rows), bad, sys.argv[4]))
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
