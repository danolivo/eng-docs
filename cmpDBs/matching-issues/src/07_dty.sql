-- Other data types: D1 .. D13.

-- D1: bytea.
CREATE TABLE dty.d01_bytea (id int PRIMARY KEY, b bytea);
INSERT INTO dty.d01_bytea VALUES (0, '\x00'), (100, '\x');
\if :n1
INSERT INTO dty.d01_bytea VALUES (1, '\x00'), (2, '\x'), (3, '\xff00'), (4, 'hello'), (5, '\x5c78'),
	(10, convert_to(repeat('0123456789abcdef', 131072), 'UTF8') || '\x01');
\else
INSERT INTO dty.d01_bytea VALUES (1, '\x0000'), (2, NULL), (3, '\xff01'),
	(10, convert_to(repeat('0123456789abcdef', 131072), 'UTF8') || '\x02');
\endif
CALL ref_meta.reg('D1', 'dty.d01_bytea', 'rows 1, 2, 3 changed, rows 4, 5 only on n1, row 10 changed (2 MB, the last byte differs); after repair every value is byte-equal');
-- D14: bytea, a type that some tools do not support.
CALL ref_meta.reg('D14', 'dty.d01_bytea', 'as D1: a tool that cannot compare bytea must say so, not skip the column');

-- D2, D3: geometric, network, range, bit, enum, xml, time, money and the
-- types that have no equality or hash operator.
CREATE TYPE dty.d02_enum AS ENUM ('one', 'two', 'three');
CREATE TABLE dty.d02_misc_types (
	id int PRIMARY KEY,
	p point, l line, ls lseg, bx box, pa path, pg polygon, ci circle,
	ine inet, cid cidr, mac macaddr, mac8 macaddr8,
	r int4range, tr tstzrange, dr daterange,
	bt bit(8), vb varbit, en dty.d02_enum, x xml,
	t time, tz timetz, m money, u uuid, js json, jb jsonb,
	tsv tsvector, tsq tsquery, bo boolean, o oid
);
INSERT INTO dty.d02_misc_types VALUES (
	0, '(1,2)', '{1,-1,0}', '[(0,0),(1,1)]', '(1,1),(0,0)', '((0,0),(1,1),(2,0))', '((0,0),(1,1),(2,0))', '<(0,0),1>',
	'10.0.0.1', '10.0.0.0/8', '08:00:2b:01:02:03', '08:00:2b:01:02:03:04:05',
	'[1,5)', '[2026-01-01 00:00:00+00,2026-02-01 00:00:00+00)', '[2026-01-01,2026-02-01)',
	B'10100000', B'101', 'one', '<a/>',
	'12:00:00', '12:00:00+00', '1.00', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '{"a":1}', '{"a": 1}',
	'a:1 b:2', 'a & b', true, 1);
\if :n1
INSERT INTO dty.d02_misc_types VALUES (
	1, '(1.5,2.5)', '{1,-1,0}', '[(0,0),(1,1)]', '(1,1),(0,0)', '[(0,0),(1,1),(2,0)]', '((0,0),(1,1),(2,0))', '<(0,0),1>',
	'10.0.0.1', '10.0.0.0/8', '08:00:2b:01:02:03', '08:00:2b:01:02:03:04:05',
	'[1,5)', '[2026-01-01 00:00:00+00,2026-02-01 00:00:00+00)', '[2026-01-01,2026-02-01)',
	B'10100000', B'101', 'one', '<a>1</a>',
	'12:00:00', '12:00:00+00', '1.00', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', '{"a":1}', '{"a": 1}',
	'a:1 b:2', 'a & b', true, 1);
INSERT INTO dty.d02_misc_types SELECT 2, p, l, ls, bx, pa, pg, ci, ine, cid, mac, mac8, r, tr, dr, bt, vb, en, x, t, tz, m, u, js, jb, tsv, tsq, bo, o
	FROM dty.d02_misc_types WHERE id = 1;
\else
INSERT INTO dty.d02_misc_types VALUES (
	1, '(1.5,2.6)', '{1,-1,1}', '[(0,0),(1,2)]', '(1,2),(0,0)', '((0,0),(1,1),(2,0))', '((0,0),(1,1),(2,1))', '<(0,0),2>',
	'10.0.0.2', '10.0.0.0/16', '08:00:2b:01:02:04', '08:00:2b:01:02:03:04:06',
	'[1,6)', '[2026-01-01 00:00:00+00,2026-02-01 00:00:00+00]', '[2026-01-01,2026-02-02)',
	B'10100001', B'1010', 'two', '<a>2</a>',
	'12:00:01', '12:00:00+01', '1.01', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a12', '{"a":2}', '{"a": 2}',
	'a:1 c:2', 'a | b', false, 2);
\endif
CALL ref_meta.reg('D2', 'dty.d02_misc_types', 'row 1 changed in every column, row 2 only on n1, row 0 equal; after repair from n1 both rows are byte-equal on n2');
CALL ref_meta.reg('D3', 'dty.d02_misc_types', 'json, xml, point and other columns without an equality or hash operator must not break the row hash');

-- D4: arrays.
CREATE TYPE dty.d04_pair AS (a int, b text);
CREATE TABLE dty.d04_arrays (id int PRIMARY KEY, na numeric[], ca dty.d04_pair[], ia int[], dra daterange[], ta text[], ba bytea[], tsa timestamptz[]);
INSERT INTO dty.d04_arrays VALUES (0, '{1.50,2}', '{"(1,a)","(2,\"b c\")"}', '{1,2,3}', '{"[2026-01-01,2026-02-01)"}', '{a,"b,c","d\"e",NULL}', '{"\\x00ff"}', '{"2026-01-01 00:00:00+00"}');
\if :n1
INSERT INTO dty.d04_arrays VALUES
	(1, '{1.50,2}', '{"(1,a)","(2,\"b c\")"}', '{1,2,3}', '{"[2026-01-01,2026-02-01)"}', '{a,"b,c","d\"e",NULL}', '{"\\x00ff"}', '{"2026-01-01 00:00:00+00"}'),
	(2, '{NaN,Infinity}', '{"(,)",NULL}', '{}', '{empty}', '{"","NULL"}', '{"\\x"}', '{infinity}');
\else
INSERT INTO dty.d04_arrays VALUES
	(1, '{1.5,2}', '{"(1,a)","(2,b c)"}', '{1,2,4}', '{"[2026-01-01,2026-02-02)"}', '{a,b,c,"d\"e",NULL}', '{"\\x00fe"}', '{"2026-01-01 00:00:00.000001+00"}');
\endif
CALL ref_meta.reg('D4', 'dty.d04_arrays', 'row 1 changed in every column but ca, row 2 only on n1; after repair the text is byte-equal');

-- D5: a domain over a composite and extension types.
CREATE TYPE dty.d05_pair AS (a int, b text);
CREATE DOMAIN dty.d05_dom_pair AS dty.d05_pair CHECK ((VALUE).a IS NOT NULL);
CREATE TABLE dty.d05_ext_types (id int PRIMARY KEY, dc dty.d05_dom_pair, h hstore, ci citext, lt ltree, vec vector(3));
INSERT INTO dty.d05_ext_types VALUES (0, '(1,a)', 'a=>1', 'Same', 'a.b', '[1,2,3]');
\if :n1
INSERT INTO dty.d05_ext_types VALUES (1, '(1,a)', 'a=>1, b=>NULL', 'Alice', 'a.b.c', '[1,2,3]'), (2, '(2,)', '', '', 'x', '[0,0,0]');
\else
INSERT INTO dty.d05_ext_types VALUES (1, '(1,b)', 'a=>1, b=>"NULL"', 'Bob', 'a.b.d', '[1,2,3.5]');
\endif
CALL ref_meta.reg('D5', 'dty.d05_ext_types', 'row 1 changed in every column, row 2 only on n1; extension types go through as text');
CALL ref_meta.reg('D9', 'dty.d05_ext_types', 'hstore NULL against the text "NULL"; pgvector');

-- D8: arrays with several dimensions, of a domain, and a big one.
CREATE DOMAIN dty.d08_dom AS int CHECK (VALUE >= 0);
CREATE TABLE dty.d08_arrays_md (id int PRIMARY KEY, m int[], da dty.d08_dom[], big int[]);
INSERT INTO dty.d08_arrays_md VALUES (0, '{{1,2},{3,4}}', '{1,2}', NULL);
\if :n1
INSERT INTO dty.d08_arrays_md VALUES (1, '{{1,2},{3,4}}', '{1,2}', (SELECT array_agg(i) FROM generate_series(1, 200000) i)), (2, '{{{1}},{{2}}}', '{}', '{}');
\else
INSERT INTO dty.d08_arrays_md VALUES (1, '{{1,2},{3,5}}', '{1,3}', (SELECT array_agg(CASE WHEN i = 200000 THEN 0 ELSE i END) FROM generate_series(1, 200000) i));
\endif
CALL ref_meta.reg('D8', 'dty.d08_arrays_md', 'row 1 changed (also the last of 200000 elements), row 2 only on n1');

-- D9: text search, ltree, pgvector.
CREATE TABLE dty.d09_ext (id int PRIMARY KEY, h hstore, lt ltree, tsv tsvector, tsq tsquery, v vector(3), hv halfvec(3), sv sparsevec(5));
INSERT INTO dty.d09_ext VALUES (0, 'a=>NULL', 'top.a', 'cat:1 dog:2', 'cat & dog', '[1,2,3]', '[1,2,3]', '{1:1,3:2}/5');
\if :n1
INSERT INTO dty.d09_ext VALUES (1, 'a=>NULL', 'top.a', 'cat:1 dog:2', 'cat & dog', '[0.1,0.2,0.3]', '[0.1,0.2,0.3]', '{1:1,3:2}/5'), (2, '', '', '', '', '[0,0,0]', '[0,0,0]', '{}/5');
\else
INSERT INTO dty.d09_ext VALUES (1, 'a=>"NULL"', 'top.b', 'cat:1 dog:3', 'cat | dog', '[0.1,0.2,0.30000001]', '[0.1,0.2,0.31]', '{1:1,4:2}/5');
\endif
CALL ref_meta.reg('D9', 'dty.d09_ext', 'row 1 changed in every column, row 2 only on n1');

-- D11: internal-looking types in a user table.
CREATE TABLE dty.d11_internal (id int PRIMARY KEY, c "char", n name, lsn pg_lsn, x8 xid8, t tid, i2v int2vector, ov oidvector);
INSERT INTO dty.d11_internal VALUES (0, 'a', 'a_name', '0/16B3748', '42', '(0,1)', '1 2 3', '1 2 3');
\if :n1
INSERT INTO dty.d11_internal VALUES (1, 'a', repeat('n', 63), '16/B374D848', '18446744073709551615', '(4294967295,65535)', '1 2 3', '4294967295 1'), (2, '', '', '0/0', '0', '(0,0)', '', '');
\else
INSERT INTO dty.d11_internal VALUES (1, 'b', repeat('n', 62) || 'm', '16/B374D849', '18446744073709551614', '(4294967295,65534)', '1 2 4', '4294967294 1');
\endif
CALL ref_meta.reg('D11', 'dty.d11_internal', 'row 1 changed in every column, row 2 only on n1');

-- D12: values that reach the same stored form from another input.
CREATE TABLE dty.d12_canonical (id int PRIMARY KEY, b bit(8), r int4range, m8 macaddr8, u uuid, ine inet, t time);
\if :n1
INSERT INTO dty.d12_canonical VALUES (1, B'101'::bit(8), '(0,4]', '08:00:2b:01:02:03'::macaddr::macaddr8, 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11', '10.0.0.1/32', '23:59:60');
\else
INSERT INTO dty.d12_canonical VALUES (1, B'10100000', '[1,5)', '08:00:2b:ff:fe:01:02:03', '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}', '10.0.0.1', '24:00:00');
\endif
CALL ref_meta.reg('D12', 'dty.d12_canonical', 'match: other input, the same stored value');

-- D13: relations that are not replicated or have no key.
CREATE UNLOGGED TABLE dty.d13_unlogged (id int PRIMARY KEY, v text);
CREATE TABLE dty.d13_src (id int PRIMARY KEY, grp int, v text);
INSERT INTO dty.d13_unlogged VALUES (1, 'same');
INSERT INTO dty.d13_src SELECT i, i % 3, 'v' || i FROM generate_series(1, 30) i;
\if :n1
INSERT INTO dty.d13_unlogged VALUES (2, 'n1'), (3, 'only n1');
\else
INSERT INTO dty.d13_unlogged VALUES (2, 'n2');
UPDATE dty.d13_src SET grp = 0 WHERE id = 1;
\endif
CREATE MATERIALIZED VIEW dty.d13_matview AS SELECT grp, count(*) AS cnt FROM dty.d13_src GROUP BY grp;
CREATE VIEW dty.d13_view AS SELECT * FROM dty.d13_src WHERE grp = 0;
CALL ref_meta.reg('D13', 'dty.d13_unlogged', 'unlogged table: row 2 changed, row 3 only on n1');
CALL ref_meta.reg('D13', 'dty.d13_src', 'row 1 changed');
CALL ref_meta.reg('D13', 'dty.d13_matview', 'materialized view without a key, content differs: listed as not compared');
CALL ref_meta.reg('D13', 'dty.d13_view', 'view: listed as not compared');
