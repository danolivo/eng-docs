-- Table structure, visibility and replication design: S1 .. S15.

-- S1: a row in the parent on n1 and in a child on n2.
CREATE TABLE str.s01_parent (id int PRIMARY KEY, v text);
CREATE TABLE str.s01_child (PRIMARY KEY (id)) INHERITS (str.s01_parent);
INSERT INTO str.s01_parent VALUES (1, 'in the parent on both');
INSERT INTO str.s01_child VALUES (2, 'in the child on both');
\if :n1
INSERT INTO str.s01_parent VALUES (3, 'moves');
\else
INSERT INTO str.s01_child VALUES (3, 'moves');
\endif
CALL ref_meta.reg('S1', 'str.s01_parent', 'the whole tree holds the same rows; row 3 is in the parent on n1 and in the child on n2. With ONLY: row 3 only on n1');
CALL ref_meta.reg('S1', 'str.s01_child', 'row 3 only on n2');

-- S2: the same key in the parent and in a child.
CREATE TABLE str.s02_parent (id int PRIMARY KEY, v text);
CREATE TABLE str.s02_child (PRIMARY KEY (id)) INHERITS (str.s02_parent);
INSERT INTO str.s02_parent VALUES (1, 'same'), (5, 'key 5 in the parent');
\if :n1
INSERT INTO str.s02_child VALUES (5, 'key 5 in the child');
\endif
CALL ref_meta.reg('S2', 'str.s02_parent', 'the tree of n1 has two rows for key 5 (parent and child), n2 has one. With ONLY the parents match');
CALL ref_meta.reg('S2', 'str.s02_child', 'row 5 only on n1');

-- S3: a partitioned table.
CREATE TABLE str.s03_part (id int PRIMARY KEY, v text) PARTITION BY RANGE (id);
CREATE TABLE str.s03_part_1 PARTITION OF str.s03_part FOR VALUES FROM (0) TO (1000);
CREATE TABLE str.s03_part_2 PARTITION OF str.s03_part FOR VALUES FROM (1000) TO (2000);
CREATE TABLE str.s03_part_def PARTITION OF str.s03_part DEFAULT;
INSERT INTO str.s03_part SELECT i, 'v' || i FROM generate_series(1, 2500) i;
\if :n2
UPDATE str.s03_part SET v = 'changed' WHERE id IN (500, 1500, 2400);
DELETE FROM str.s03_part WHERE id IN (999, 1000);
\endif
CALL ref_meta.reg('S3', 'str.s03_part', '3 changed rows, 2 rows only on n1 (one in each of the two first partitions); SELECT FROM ONLY gives 0 rows on both nodes and must not be read as a match');

-- S4: other partition bounds; partitioned on one node only.
CREATE TABLE str.s04_part_bounds (id int PRIMARY KEY, v text) PARTITION BY RANGE (id);
\if :n1
CREATE TABLE str.s04_part_bounds_p1 PARTITION OF str.s04_part_bounds FOR VALUES FROM (0) TO (100);
CREATE TABLE str.s04_part_bounds_p2 PARTITION OF str.s04_part_bounds FOR VALUES FROM (100) TO (200);
CREATE TABLE str.s04_part_one_side (id int PRIMARY KEY, v text) PARTITION BY RANGE (id);
CREATE TABLE str.s04_part_one_side_p1 PARTITION OF str.s04_part_one_side FOR VALUES FROM (0) TO (1000);
\else
CREATE TABLE str.s04_part_bounds_p1 PARTITION OF str.s04_part_bounds FOR VALUES FROM (0) TO (50);
CREATE TABLE str.s04_part_bounds_p2 PARTITION OF str.s04_part_bounds FOR VALUES FROM (50) TO (200);
CREATE TABLE str.s04_part_one_side (id int PRIMARY KEY, v text);
\endif
INSERT INTO str.s04_part_bounds SELECT i, 'v' || i FROM generate_series(1, 199) i;
INSERT INTO str.s04_part_one_side SELECT i, 'v' || i FROM generate_series(1, 100) i;
CALL ref_meta.reg('S4', 'str.s04_part_bounds', 'match through the root; the rows 50-99 are in p1 on n1 and in p2 on n2, so the leaves differ');
CALL ref_meta.reg('S4', 'str.s04_part_one_side', 'match; the table is partitioned on n1 and plain on n2');

-- S5: foreign children and partitions.
DO $$
BEGIN
	EXECUTE format('CREATE SERVER ace_ref_loopback FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L)',
		'localhost', current_setting('port'), current_database());
	EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER ace_ref_loopback OPTIONS (user %L)', current_user);
END $$;
CREATE TABLE str.s05_remote (id int PRIMARY KEY, v text);
CREATE TABLE str.s05_parent (id int PRIMARY KEY, v text);
CREATE FOREIGN TABLE str.s05_child_foreign () INHERITS (str.s05_parent) SERVER ace_ref_loopback OPTIONS (schema_name 'str', table_name 's05_remote');
CREATE FOREIGN TABLE str.s05_foreign_only (id int, v text) SERVER ace_ref_loopback OPTIONS (schema_name 'str', table_name 's05_remote');
INSERT INTO str.s05_parent VALUES (1, 'local row'), (2, 'local row');
INSERT INTO str.s05_remote VALUES (10, 'remote row'), (11, 'remote row');
\if :n2
UPDATE str.s05_parent SET v = 'changed' WHERE id = 2;
UPDATE str.s05_remote SET v = 'changed' WHERE id = 11;
\endif
CALL ref_meta.reg('S5', 'str.s05_parent', 'row 2 of the parent changed; the foreign child shows row 11 as changed too: compared only for the heap part, with a clear message about the foreign child');
CALL ref_meta.reg('S5', 'str.s05_foreign_only', 'foreign table: refused or listed as not compared');
CALL ref_meta.reg('S5', 'str.s05_remote', 'row 11 changed');

-- S6: a child without a primary key.
CREATE TABLE str.s06_parent (id int PRIMARY KEY, v text);
CREATE TABLE str.s06_child_nopk () INHERITS (str.s06_parent);
INSERT INTO str.s06_parent VALUES (1, 'same');
INSERT INTO str.s06_child_nopk VALUES (2, 'same'), (3, 'x');
\if :n2
UPDATE str.s06_child_nopk SET v = 'changed' WHERE id = 3;
INSERT INTO str.s06_child_nopk VALUES (2, 'duplicate key in the child');
\endif
CALL ref_meta.reg('S6', 'str.s06_parent', 'the parents match; the child has no key');
CALL ref_meta.reg('S6', 'str.s06_child_nopk', 'no primary key, a duplicate id on n2: listed as not compared, exit code not zero');

-- S7: extreme shapes.
CREATE TABLE str.s07_key_only (id int PRIMARY KEY);
CREATE TABLE str.s07_key_only_comp (a int, b text, PRIMARY KEY (a, b));
INSERT INTO str.s07_key_only VALUES (1), (2);
INSERT INTO str.s07_key_only_comp VALUES (1, 'a'), (2, 'b');
\if :n1
INSERT INTO str.s07_key_only VALUES (3);
INSERT INTO str.s07_key_only_comp VALUES (3, 'c');
\else
INSERT INTO str.s07_key_only VALUES (4);
INSERT INTO str.s07_key_only_comp VALUES (3, 'C');
\endif
DO $$
BEGIN
	EXECUTE 'CREATE TABLE str.s07_wide_1600 (id int PRIMARY KEY, '
		|| (SELECT string_agg('c' || lpad(i::text, 4, '0') || ' int', ', ' ORDER BY i) FROM generate_series(1, 1599) i) || ')';
	EXECUTE 'INSERT INTO str.s07_wide_1600 SELECT r, '
		|| (SELECT string_agg(i::text, ', ' ORDER BY i) FROM generate_series(1, 1599) i)
		|| ' FROM generate_series(1, 5) r';
END $$;
\if :n2
UPDATE str.s07_wide_1600 SET c1599 = -1 WHERE id = 2;
DELETE FROM str.s07_wide_1600 WHERE id = 5;
\endif
CALL ref_meta.reg('S7', 'str.s07_key_only', 'row 3 only on n1, row 4 only on n2; the table has no column to update');
CALL ref_meta.reg('S7', 'str.s07_key_only_comp', 'key (3, c) only on n1, key (3, C) only on n2');
CALL ref_meta.reg('S7', 'str.s07_wide_1600', '1600 columns: row 2 changed in the last column, row 5 only on n1');
CALL ref_meta.reg('K11', 'str.s07_wide_1600', 'the widest table that PostgreSQL allows');

-- S8: row level security hides rows from the role ace_ref_reader on n2.
CREATE TABLE str.s08_rls (id int PRIMARY KEY, tenant text, v text);
INSERT INTO str.s08_rls VALUES (1, 'a', 'x'), (2, 'a', 'x'), (3, 'b', 'x'), (4, 'b', 'x');
\if :n2
ALTER TABLE str.s08_rls ENABLE ROW LEVEL SECURITY;
ALTER TABLE str.s08_rls FORCE ROW LEVEL SECURITY;
CREATE POLICY s08_tenant_a ON str.s08_rls FOR ALL TO ace_ref_reader USING (tenant = 'a');
\endif
CALL ref_meta.reg('S8', 'str.s08_rls', 'match for a superuser. For the role ace_ref_reader the rows 3, 4 are hidden on n2: a false "only on n1", and a repair INSERT hits the unique index');
-- P20: a dump made under row level security.
CALL ref_meta.reg('P20', 'str.s08_rls', 'a dump made under this policy holds only the rows 1, 2');

-- S9: the role ace_ref_reader cannot read one column on n2.
CREATE TABLE str.s09_col_priv (id int PRIMARY KEY, public_v text, secret text);
INSERT INTO str.s09_col_priv VALUES (1, 'a', 's1'), (2, 'b', 's2');
CALL ref_meta.reg('S9', 'str.s09_col_priv', 'match for a superuser. The role ace_ref_reader has no SELECT on the column secret on n2: a clear error, no partial comparison');

-- S10: a rule sends the INSERT of a repair to another table.
CREATE TABLE str.s10_rule (id int PRIMARY KEY, v text);
CREATE TABLE str.s10_rule_sink (id int, v text);
INSERT INTO str.s10_rule VALUES (1, 'same');
\if :n1
INSERT INTO str.s10_rule VALUES (2, 'only n1');
\else
CREATE RULE s10_redirect AS ON INSERT TO str.s10_rule DO INSTEAD INSERT INTO str.s10_rule_sink VALUES (NEW.id, NEW.v);
\endif
CALL ref_meta.reg('S10', 'str.s10_rule', 'row 2 only on n1; a repair INSERT on n2 lands in str.s10_rule_sink and changes no row of the table: must be a failed row operation');

-- S11: rows that are absent on n2 by a row filter of the replication set.
CREATE TABLE str.s11_row_filter (id int PRIMARY KEY, region text, v text);
\if :n1
INSERT INTO str.s11_row_filter SELECT i, (ARRAY['eu','us','asia'])[1 + i % 3], 'v' || i FROM generate_series(1, 300) i;
\else
INSERT INTO str.s11_row_filter SELECT i, 'eu', 'v' || i FROM generate_series(1, 300) i WHERE i % 3 = 0;
\endif
CALL ref_meta.reg('S11', 'str.s11_row_filter', '200 rows only on n1 (us, asia) by design; with the table filter region = ''eu'' the tables match');

-- S12: a column that is not replicated to n2.
CREATE TABLE str.s12_col_filter (id int PRIMARY KEY, v text, internal_note text);
\if :n1
INSERT INTO str.s12_col_filter SELECT i, 'v' || i, 'note ' || i FROM generate_series(1, 100) i;
\else
INSERT INTO str.s12_col_filter SELECT i, 'v' || i, NULL FROM generate_series(1, 100) i;
\endif
CALL ref_meta.reg('S12', 'str.s12_col_filter', 'all 100 rows differ in internal_note only, by design');

-- S13: a counter merged by delta.
CREATE TABLE str.s13_counter (id int PRIMARY KEY, cnt bigint NOT NULL);
\if :n1
INSERT INTO str.s13_counter VALUES (1, 100), (2, 200), (3, 300);
\else
INSERT INTO str.s13_counter VALUES (1, 100), (2, 205), (3, 299);
\endif
CALL ref_meta.reg('S13', 'str.s13_counter', 'rows 2, 3 changed; no node holds the right value, so a copy from one side loses updates');

-- S14: a volatile default added by a DDL that ran on each node.
CREATE TABLE str.s14_volatile_default (id int PRIMARY KEY, v text);
INSERT INTO str.s14_volatile_default SELECT i, 'v' || i FROM generate_series(1, 20000) i;
ALTER TABLE str.s14_volatile_default ADD COLUMN token uuid DEFAULT gen_random_uuid();
ALTER TABLE str.s14_volatile_default ADD COLUMN noise float8 DEFAULT random();
CALL ref_meta.reg('S14', 'str.s14_volatile_default', 'all 20000 rows differ in token and noise: a whole-table difference (a test of the limit of reported rows, of memory and of the report size)');

-- S15: a trigger that changes the row which a repair writes.
CREATE TABLE str.s15_trigger_always (id int PRIMARY KEY, v text, updated_at timestamptz);
CREATE TABLE str.s15_trigger_plain (id int PRIMARY KEY, v text, updated_at timestamptz);
INSERT INTO str.s15_trigger_always VALUES (1, 'same', '2026-01-01 00:00:00+00');
INSERT INTO str.s15_trigger_plain VALUES (1, 'same', '2026-01-01 00:00:00+00');
\if :n1
INSERT INTO str.s15_trigger_always VALUES (2, 'n1', '2026-01-02 00:00:00+00'), (3, 'only n1', '2026-01-03 00:00:00+00');
INSERT INTO str.s15_trigger_plain VALUES (2, 'n1', '2026-01-02 00:00:00+00'), (3, 'only n1', '2026-01-03 00:00:00+00');
\else
INSERT INTO str.s15_trigger_always VALUES (2, 'n2', '2026-01-02 00:00:00+00');
INSERT INTO str.s15_trigger_plain VALUES (2, 'n2', '2026-01-02 00:00:00+00');
\endif
CREATE FUNCTION str.s15_touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
	NEW.updated_at := clock_timestamp();
	RETURN NEW;
END $$;
CREATE TRIGGER s15_touch BEFORE INSERT OR UPDATE ON str.s15_trigger_always FOR EACH ROW EXECUTE FUNCTION str.s15_touch();
CREATE TRIGGER s15_touch BEFORE INSERT OR UPDATE ON str.s15_trigger_plain FOR EACH ROW EXECUTE FUNCTION str.s15_touch();
ALTER TABLE str.s15_trigger_always ENABLE ALWAYS TRIGGER s15_touch;
CALL ref_meta.reg('S15', 'str.s15_trigger_always', 'row 2 changed, row 3 only on n1; after a repair the trigger sets updated_at again, so the rows 2, 3 differ in the next diff: no run converges');
CALL ref_meta.reg('S15', 'str.s15_trigger_plain', 'as s15_trigger_always, but only when the repair fires triggers');
-- P12: triggers that fire in a data-only restore.
CALL ref_meta.reg('P12', 'str.s15_trigger_plain', 'a data-only restore without --disable-triggers fires this trigger');
