-- Keys and block bounds: K1 .. K20.
-- Tables for the tests of bounds hold a few thousand rows, so that a small
-- block size gives many blocks.

-- K1: uuid key.
CREATE TABLE key.k01_uuid (id uuid PRIMARY KEY, v text);
INSERT INTO key.k01_uuid SELECT md5(i::text)::uuid, 'v' || i FROM generate_series(1, 3000) i;
\if :n1
INSERT INTO key.k01_uuid VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'only n1');
\else
UPDATE key.k01_uuid SET v = 'changed' WHERE id IN (SELECT md5(i::text)::uuid FROM generate_series(100, 3000, 400) i);
DELETE FROM key.k01_uuid WHERE id = md5('7')::uuid;
INSERT INTO key.k01_uuid VALUES ('00000000-0000-0000-0000-000000000000', 'only n2');
\endif
CALL ref_meta.reg('K1', 'key.k01_uuid', '8 changed rows, 2 rows only on n1, 1 row only on n2; rerun and the stale check must find uuid keys');
CALL ref_meta.reg('K2', 'key.k01_uuid', 'bounds of uuid keys must be sorted as the server sorts them');
-- R15: a key in a repair plan that is written in another form.
CALL ref_meta.reg('R15', 'key.k01_uuid', 'a plan with a uuid key in upper case does not match the key text');

-- K2: keys whose text order is not their order.
CREATE TABLE key.k02_bytea_key (id bytea PRIMARY KEY, v text);
CREATE TABLE key.k02_numeric_order (id numeric PRIMARY KEY, v text);
CREATE TABLE key.k02_money_key (id money PRIMARY KEY, v text);
CREATE TYPE key.k02_size AS ENUM ('xs', 's', 'm', 'l', 'xl');
CREATE TABLE key.k02_enum_key (sz key.k02_size, n int, v text, PRIMARY KEY (sz, n));
INSERT INTO key.k02_bytea_key SELECT decode(md5(i::text), 'hex'), 'v' || i FROM generate_series(1, 3000) i;
INSERT INTO key.k02_numeric_order SELECT i * 1.5, 'v' || i FROM generate_series(1, 3000) i;
INSERT INTO key.k02_money_key SELECT (i * 3.33)::numeric::money, 'v' || i FROM generate_series(1, 3000) i;
INSERT INTO key.k02_enum_key SELECT (enum_range(NULL::key.k02_size))[1 + i % 5], i, 'v' || i FROM generate_series(1, 3000) i;
\if :n2
UPDATE key.k02_bytea_key SET v = 'changed' WHERE id IN (SELECT decode(md5(i::text), 'hex') FROM generate_series(100, 3000, 400) i);
UPDATE key.k02_numeric_order SET v = 'changed' WHERE id IN (9, 10.5, 99, 100.5, 999, 1000.5, 1500, 4498.5, 4500);
UPDATE key.k02_money_key SET v = 'changed' WHERE id IN (SELECT (i * 3.33)::numeric::money FROM generate_series(100, 3000, 400) i);
UPDATE key.k02_enum_key SET v = 'changed' WHERE n IN (SELECT generate_series(100, 3000, 400));
\endif
CALL ref_meta.reg('K2', 'key.k02_bytea_key', '8 changed rows');
CALL ref_meta.reg('K18', 'key.k02_bytea_key', 'bytea key');
CALL ref_meta.reg('K2', 'key.k02_numeric_order', '9 changed rows around 9 / 10, 99 / 100, 999 / 1000');
CALL ref_meta.reg('K2', 'key.k02_money_key', '8 changed rows');
CALL ref_meta.reg('K2', 'key.k02_enum_key', '8 changed rows; an enum sorts by its position, not by its label');

-- K3: timestamp, date and timestamptz keys.
CREATE TABLE key.k03_ts_key (id timestamp PRIMARY KEY, v text);
CREATE TABLE key.k03_date_key (id date PRIMARY KEY, v text);
CREATE TABLE key.k03_tstz_key (id timestamptz PRIMARY KEY, v text);
INSERT INTO key.k03_ts_key SELECT '2026-01-01'::timestamp + i * interval '1 hour 1 second', 'v' || i FROM generate_series(1, 2000) i;
INSERT INTO key.k03_date_key SELECT '2020-01-01'::date + i, 'v' || i FROM generate_series(1, 2000) i;
INSERT INTO key.k03_tstz_key SELECT '2026-01-01 00:00:00+00'::timestamptz + i * interval '1 hour 0.000001 second', 'v' || i FROM generate_series(1, 2000) i;
INSERT INTO key.k03_ts_key VALUES ('infinity', 'same'), ('-infinity', 'same');
INSERT INTO key.k03_date_key VALUES ('infinity', 'same'), ('0044-03-15 BC', 'same');
INSERT INTO key.k03_tstz_key VALUES ('infinity', 'same'), ('-infinity', 'same');
\if :n2
UPDATE key.k03_ts_key SET v = 'changed' WHERE id IN ('2026-01-01'::timestamp + 500 * interval '1 hour 1 second', 'infinity');
UPDATE key.k03_date_key SET v = 'changed' WHERE id IN ('2020-01-01'::date + 500, '0044-03-15 BC');
UPDATE key.k03_tstz_key SET v = 'changed' WHERE id IN ('2026-01-01 00:00:00+00'::timestamptz + 500 * interval '1 hour 0.000001 second', '-infinity');
DELETE FROM key.k03_ts_key WHERE id = '2026-01-01'::timestamp + 600 * interval '1 hour 1 second';
DELETE FROM key.k03_date_key WHERE id = '2020-01-01'::date + 600;
DELETE FROM key.k03_tstz_key WHERE id = '2026-01-01 00:00:00+00'::timestamptz + 600 * interval '1 hour 0.000001 second';
\endif
CALL ref_meta.reg('K3', 'key.k03_ts_key', '2 changed rows (one is the key infinity), 1 row only on n1');
CALL ref_meta.reg('K3', 'key.k03_date_key', '2 changed rows (one is a BC date), 1 row only on n1');
CALL ref_meta.reg('K18', 'key.k03_date_key', 'BC date as a key');
CALL ref_meta.reg('K3', 'key.k03_tstz_key', '2 changed rows (one is the key -infinity), 1 row only on n1');
CALL ref_meta.reg('R15', 'key.k03_tstz_key', 'a plan with a timestamp key in ISO "T" form does not match the key text');

-- K4: the key lists its columns in another order than the table.
CREATE TABLE key.k04_pk_order (id int, grp int, payload text, PRIMARY KEY (grp, id));
INSERT INTO key.k04_pk_order SELECT i, i % 7, 'v' || i FROM generate_series(1, 3000) i;
\if :n2
UPDATE key.k04_pk_order SET payload = 'changed' WHERE id IN (SELECT generate_series(100, 3000, 400));
DELETE FROM key.k04_pk_order WHERE id = 7;
\endif
CALL ref_meta.reg('K4', 'key.k04_pk_order', '8 changed rows, 1 row only on n1');

-- K5: the key ranges of the nodes do not overlap in part.
CREATE TABLE key.k05_range_gap (id int PRIMARY KEY, v text);
\if :n1
INSERT INTO key.k05_range_gap SELECT i, 'v' || i FROM generate_series(100, 1000) i;
\else
INSERT INTO key.k05_range_gap SELECT i, 'v' || i FROM generate_series(1, 1100) i;
\endif
CALL ref_meta.reg('K5', 'key.k05_range_gap', '199 rows only on n2: 99 below the lowest key of n1 and 100 above its highest key');

-- K6: differences at keys that are likely to be block bounds.
CREATE TABLE key.k06_boundary (id int PRIMARY KEY, v text);
INSERT INTO key.k06_boundary SELECT i, 'v' || i FROM generate_series(1, 20000) i;
\if :n2
UPDATE key.k06_boundary SET v = 'changed' WHERE id % 1000 IN (0, 1, 999) OR id IN (1, 20000);
\endif
CALL ref_meta.reg('K6', 'key.k06_boundary', '60 changed rows at ids 1, 999, 1000, 1001, ..., 19999, 20000; each is reported once');

-- K7: text keys that look like numbers.
CREATE TABLE key.k07_mixed_text_key (id text PRIMARY KEY, v text);
INSERT INTO key.k07_mixed_text_key VALUES ('1', 'same'), ('2', 'same'), ('9', 'same'), ('100', 'same');
\if :n1
INSERT INTO key.k07_mixed_text_key VALUES ('10', 'n1'), ('1a', 'n1'), ('007', 'n1'), ('1.5', 'only n1'), ('1e3', 'only n1'), ('-1', 'n1'), (' 1', 'only n1'), ('7', 'n1'), ('1.50', 'only n1');
\else
INSERT INTO key.k07_mixed_text_key VALUES ('10', 'n2'), ('1a', 'n2'), ('007', 'n2'), ('-1', 'n2'), ('7', 'n2');
\endif
CALL ref_meta.reg('K7', 'key.k07_mixed_text_key', '5 keys changed (10, 1a, 007, -1, 7), 4 keys only on n1 (1.5, 1e3, " 1", 1.50); a plan range 1..2 must not take 1.5');
CALL ref_meta.reg('R7', 'key.k07_mixed_text_key', 'plan keys 007, 1.50 and 1e3 must stay text');

-- K8: identifiers that need quotes.
CREATE TABLE key."K08 Mixed Case" ("Id" int PRIMARY KEY, "Select" text, "col with space" text, "кириллица" text, "a""b" text, "UPPER" text);
INSERT INTO key."K08 Mixed Case" VALUES (0, 's', 'c', 'k', 'q', 'u');
\if :n1
INSERT INTO key."K08 Mixed Case" VALUES (1, 's1', 'c1', 'k1', 'q1', 'u1'), (2, 's', 'c', 'k', 'q', 'u');
\else
INSERT INTO key."K08 Mixed Case" VALUES (1, 's2', 'c2', 'k2', 'q2', 'u2');
\endif
CALL ref_meta.reg('K8', 'key."K08 Mixed Case"', 'row 1 changed in every column, row 2 only on n1');

-- K9: columns named like the aliases that a row read uses.
CREATE TABLE key.k09_alias_names (id int PRIMARY KEY, _ace_k text, _ace_pos int, _ace_row_hash text, _ace_t text, _ace_keys text, _ace_row text, commit_ts text, node_origin text, pos int, ord int, k text, c text);
INSERT INTO key.k09_alias_names VALUES (0, 'a', 1, 'h', 't', 'k', 'r', 'ts', 'o', 1, 1, 'k', 'c');
\if :n1
INSERT INTO key.k09_alias_names VALUES (1, 'a', 1, 'h', 't', 'k', 'r', 'ts', 'o', 1, 1, 'k', 'c'), (2, 'a', 1, 'h', 't', 'k', 'r', 'ts', 'o', 1, 1, 'k', 'c');
\else
INSERT INTO key.k09_alias_names VALUES (1, 'b', 2, 'i', 'u', 'l', 's', 'tt', 'p', 2, 2, 'l', 'd');
\endif
CALL ref_meta.reg('K9', 'key.k09_alias_names', 'row 1 changed in every column, row 2 only on n1; no name collision in the queries');

-- K10: keys of types that a client driver does not know.
CREATE DOMAIN key.k10_dom AS int CHECK (VALUE > 0);
CREATE TABLE key.k10_ltree_key (id ltree PRIMARY KEY, v text);
CREATE TABLE key.k10_hstore_key (id hstore PRIMARY KEY, v text);
CREATE TABLE key.k10_domain_key (id key.k10_dom PRIMARY KEY, v text);
CREATE TABLE key.k10_range_key (id int4range PRIMARY KEY, v text);
INSERT INTO key.k10_ltree_key VALUES ('a', 'same'), ('a.b', 'same');
INSERT INTO key.k10_hstore_key VALUES ('a=>1', 'same');
INSERT INTO key.k10_domain_key VALUES (1, 'same');
INSERT INTO key.k10_range_key VALUES ('[1,5)', 'same'), ('empty', 'same');
\if :n1
INSERT INTO key.k10_ltree_key VALUES ('a.b.c', 'n1'), ('a.c', 'only n1');
INSERT INTO key.k10_hstore_key VALUES ('a=>1, b=>2', 'n1'), ('c=>NULL', 'only n1');
INSERT INTO key.k10_domain_key VALUES (2, 'n1'), (3, 'only n1');
INSERT INTO key.k10_range_key VALUES ('[5,9)', 'n1'), ('(,)', 'only n1');
\else
INSERT INTO key.k10_ltree_key VALUES ('a.b.c', 'n2');
INSERT INTO key.k10_hstore_key VALUES ('b=>2, a=>1', 'n2');
INSERT INTO key.k10_domain_key VALUES (2, 'n2');
INSERT INTO key.k10_range_key VALUES ('[5,9)', 'n2');
\endif
CALL ref_meta.reg('K10', 'key.k10_ltree_key', '1 key changed, 1 key only on n1');
CALL ref_meta.reg('K10', 'key.k10_hstore_key', '1 key changed (hstore orders its keys), 1 key only on n1');
CALL ref_meta.reg('K10', 'key.k10_domain_key', '1 key changed, 1 key only on n1; the key is cast to the base type of the domain');
CALL ref_meta.reg('K10', 'key.k10_range_key', '1 key changed, 1 key only on n1');

-- K11: a table with more than 100 columns.
DO $$
BEGIN
	EXECUTE 'CREATE TABLE key.k11_wide_120 (id int PRIMARY KEY, '
		|| (SELECT string_agg('c' || lpad(i::text, 3, '0') || ' int', ', ' ORDER BY i) FROM generate_series(1, 120) i) || ')';
	EXECUTE 'INSERT INTO key.k11_wide_120 SELECT r, '
		|| (SELECT string_agg('r + ' || i, ', ' ORDER BY i) FROM generate_series(1, 120) i)
		|| ' FROM generate_series(1, 50) r';
END $$;
\if :n2
UPDATE key.k11_wide_120 SET c120 = -1 WHERE id = 10;
UPDATE key.k11_wide_120 SET c001 = -1 WHERE id = 20;
DELETE FROM key.k11_wide_120 WHERE id = 30;
\endif
CALL ref_meta.reg('K11', 'key.k11_wide_120', 'rows 10, 20 changed (last and first column), row 30 only on n1');

-- K12: tables without a primary key.
CREATE TABLE key.k12_unique_notnull (id int NOT NULL UNIQUE, v text);
CREATE TABLE key.k12_replident_index (id int NOT NULL, v text);
CREATE UNIQUE INDEX k12_replident_index_id ON key.k12_replident_index (id);
ALTER TABLE key.k12_replident_index REPLICA IDENTITY USING INDEX k12_replident_index_id;
CREATE TABLE key.k12_replident_full (id int, v text);
ALTER TABLE key.k12_replident_full REPLICA IDENTITY FULL;
INSERT INTO key.k12_unique_notnull VALUES (1, 'same'), (2, 'x');
INSERT INTO key.k12_replident_index VALUES (1, 'same'), (2, 'x');
INSERT INTO key.k12_replident_full VALUES (1, 'same'), (2, 'x'), (2, 'x');
\if :n2
UPDATE key.k12_unique_notnull SET v = 'changed' WHERE id = 2;
UPDATE key.k12_replident_index SET v = 'changed' WHERE id = 2;
DELETE FROM key.k12_replident_full WHERE ctid = (SELECT max(ctid) FROM key.k12_replident_full);
\endif
CALL ref_meta.reg('K12', 'key.k12_unique_notnull', 'no primary key, a UNIQUE NOT NULL column: refused with a clear message, or row 2 changed');
CALL ref_meta.reg('K12', 'key.k12_replident_index', 'no primary key, REPLICA IDENTITY USING INDEX: refused with a clear message, or row 2 changed');
CALL ref_meta.reg('K12', 'key.k12_replident_full', 'no key at all, a duplicate row on n1: cannot be compared; must be listed as not compared');

-- K13: the key definition differs.
\if :n1
CREATE TABLE key.k13_pk_differs (id int, region text, v text, PRIMARY KEY (id));
INSERT INTO key.k13_pk_differs VALUES (1, 'eu', 'a'), (2, 'us', 'b');
\else
CREATE TABLE key.k13_pk_differs (id int, region text, v text, PRIMARY KEY (id, region));
INSERT INTO key.k13_pk_differs VALUES (1, 'eu', 'a'), (1, 'us', 'a2'), (2, 'us', 'b');
\endif
CALL ref_meta.reg('K13', 'key.k13_pk_differs', 'the key is (id) on n1 and (id, region) on n2: refused at the start with a clear message');

-- K14: a deferrable primary key.
CREATE TABLE key.k14_deferrable_pk (id int, v text, PRIMARY KEY (id) DEFERRABLE INITIALLY DEFERRED);
INSERT INTO key.k14_deferrable_pk VALUES (1, 'same');
\if :n1
INSERT INTO key.k14_deferrable_pk VALUES (2, 'n1'), (3, 'only n1');
\else
INSERT INTO key.k14_deferrable_pk VALUES (2, 'n2');
\endif
CALL ref_meta.reg('K14', 'key.k14_deferrable_pk', 'row 2 changed, row 3 only on n1; ON CONFLICT cannot use this key; a violation shows only at COMMIT');

-- K15: key text with special characters.
CREATE TABLE key.k15_special_keys (id text PRIMARY KEY, v text);
INSERT INTO key.k15_special_keys VALUES ('same', 'x');
\if :n1
INSERT INTO key.k15_special_keys VALUES
	('', 'n1'), (' ', 'n1'), ('  ', 'only n1'), ('a,b', 'n1'), ('a"b', 'only n1'), ('{a}', 'n1'), (E'a\\b', 'only n1'),
	(E'a\nb', 'n1'), ('NULL', 'only n1'), (repeat('k', 2000), 'n1'), (repeat('k', 1999) || 'j', 'only n1'), ('a''b', 'n1');
\else
INSERT INTO key.k15_special_keys VALUES
	('', 'n2'), (' ', 'n2'), ('a,b', 'n2'), ('{a}', 'n2'), (E'a\nb', 'n2'), (repeat('k', 2000), 'n2'), ('a''b', 'n2');
\endif
CALL ref_meta.reg('K15', 'key.k15_special_keys', '7 keys changed, 5 keys only on n1');

-- K16: the collation of a text key differs between the nodes.
\if :n1
CREATE TABLE key.k16_key_collation (id text COLLATE "C" PRIMARY KEY, v text);
\else
CREATE TABLE key.k16_key_collation (id text COLLATE "en-x-icu" PRIMARY KEY, v text);
\endif
INSERT INTO key.k16_key_collation
	SELECT CASE WHEN i % 2 = 0 THEN chr(65 + i % 26) ELSE chr(97 + i % 26) END || '-' || lpad(i::text, 5, '0'), 'v' || i
	FROM generate_series(1, 5000) i;
INSERT INTO key.k16_key_collation VALUES ('a-a', 'x'), ('a+a', 'x'), ('aa', 'x'), ('_x', 'x');
\if :n2
UPDATE key.k16_key_collation SET v = 'changed' WHERE id IN (SELECT CASE WHEN i % 2 = 0 THEN chr(65 + i % 26) ELSE chr(97 + i % 26) END || '-' || lpad(i::text, 5, '0') FROM unnest(ARRAY[1, 26, 5000]) i);
\endif
CALL ref_meta.reg('K16', 'key.k16_key_collation', '3 changed rows and nothing else; the key sorts as C on n1 and as ICU on n2, so a range of keys selects other rows on each node');

-- K19: skewed keys.
CREATE TABLE key.k19_skewed (tenant int, id bigint, v text, PRIMARY KEY (tenant, id));
INSERT INTO key.k19_skewed SELECT 1, i, 'v' || i FROM generate_series(1, 5000) i;
INSERT INTO key.k19_skewed SELECT 1, 1000000000000 + i, 'v' || i FROM generate_series(1, 5000) i;
INSERT INTO key.k19_skewed VALUES (2, 1, 'lonely');
\if :n2
UPDATE key.k19_skewed SET v = 'changed' WHERE (tenant, id) IN ((1, 1), (1, 5000), (1, 1000000000001), (1, 1000000005000), (2, 1));
\endif
CALL ref_meta.reg('K19', 'key.k19_skewed', '5 changed rows: at both ends of each cluster of keys and the lonely row');

-- K20: tiny tables.
CREATE TABLE key.k20_empty_both (id int PRIMARY KEY, v text);
CREATE TABLE key.k20_empty_n1 (id int PRIMARY KEY, v text);
CREATE TABLE key.k20_empty_n2 (id int PRIMARY KEY, v text);
CREATE TABLE key.k20_one_row (id int PRIMARY KEY, v text);
CREATE TABLE key.k20_one_row_diff (id int PRIMARY KEY, v text);
INSERT INTO key.k20_one_row VALUES (1, 'same');
\if :n1
INSERT INTO key.k20_empty_n2 VALUES (1, 'a'), (2, 'b'), (3, 'c');
INSERT INTO key.k20_one_row_diff VALUES (1, 'n1');
\else
INSERT INTO key.k20_empty_n1 VALUES (1, 'a'), (2, 'b'), (3, 'c');
INSERT INTO key.k20_one_row_diff VALUES (1, 'n2');
\endif
CALL ref_meta.reg('K20', 'key.k20_empty_both', 'match: empty on both nodes');
CALL ref_meta.reg('K20', 'key.k20_empty_n1', '3 rows only on n2; n1 is empty');
CALL ref_meta.reg('K5', 'key.k20_empty_n1', 'the table is empty on the first node');
CALL ref_meta.reg('K20', 'key.k20_empty_n2', '3 rows only on n1; n2 is empty');
CALL ref_meta.reg('K20', 'key.k20_one_row', 'match: one row');
CALL ref_meta.reg('K20', 'key.k20_one_row_diff', '1 changed row');
