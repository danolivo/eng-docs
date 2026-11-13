-- Repair: R2 .. R12. Run the diff, then the repair from n1 to n2.

-- R2: a table for changes between the diff and the repair.
CREATE TABLE rep.r02_stale (id int PRIMARY KEY, v text);
INSERT INTO rep.r02_stale VALUES (0, 'same');
\if :n1
INSERT INTO rep.r02_stale VALUES (1, 'n1'), (2, 'n1'), (3, 'only n1'), (4, 'only n1'), (5, 'n1');
\else
INSERT INTO rep.r02_stale VALUES (1, 'n2'), (2, 'n2'), (5, 'n2'), (6, 'only n2');
\endif
CALL ref_meta.reg('R2', 'rep.r02_stale', 'rows 1, 2, 5 changed, rows 3, 4 only on n1, row 6 only on n2. After the diff run on n2: DELETE FROM rep.r02_stale WHERE id = 1; UPDATE rep.r02_stale SET v = ''new'' WHERE id = 2; INSERT INTO rep.r02_stale VALUES (3, ''new''); DELETE FROM rep.r02_stale WHERE id = 6. Then the repair: each of these rows is a failed (stale) row operation, the rows 4 and 5 are applied');

-- R3: constraints that exist on the target only.
CREATE TABLE rep.r03_parent (id int PRIMARY KEY);
INSERT INTO rep.r03_parent VALUES (1);
\if :n1
CREATE TABLE rep.r03_constraints (id int PRIMARY KEY, qty int, code text, parent_id int);
INSERT INTO rep.r03_constraints VALUES (0, 1, 'SAME', 1), (1, -5, 'A', 1), (2, 5, 'DUP', 1), (3, 5, 'C', 999), (4, 5, 'D', 1);
\else
CREATE TABLE rep.r03_constraints (id int PRIMARY KEY, qty int CHECK (qty > 0), code text UNIQUE, parent_id int REFERENCES rep.r03_parent);
INSERT INTO rep.r03_constraints VALUES (0, 1, 'SAME', 1), (9, 1, 'DUP', 1);
\endif
CALL ref_meta.reg('R3', 'rep.r03_constraints', 'rows 1-4 only on n1, row 9 only on n2. Repair n1 -> n2: row 1 fails (CHECK), row 2 fails (UNIQUE, while row 9 exists), row 3 has no parent (fails only when the FK trigger fires), row 4 is applied');
-- R1: row operations of a repair that fail must not be hidden.
CALL ref_meta.reg('R1', 'rep.r03_constraints', 'failed rows must be reported; the repair must not end as a plain success');

-- R5: a key that is equal by the operator, with ON DELETE CASCADE.
CREATE TABLE rep.r05_parent (id numeric PRIMARY KEY, v text);
CREATE TABLE rep.r05_child (id int PRIMARY KEY, parent_id numeric REFERENCES rep.r05_parent ON DELETE CASCADE, v text);
\if :n1
INSERT INTO rep.r05_parent VALUES (1.50, 'parent');
INSERT INTO rep.r05_child VALUES (1, 1.50, 'child'), (2, 1.50, 'child');
\else
INSERT INTO rep.r05_parent VALUES (1.5, 'parent');
INSERT INTO rep.r05_child VALUES (1, 1.5, 'child'), (2, 1.5, 'child');
\endif
CALL ref_meta.reg('R5', 'rep.r05_parent', 'key 1.50 only on n1, key 1.5 only on n2. When the repair fires triggers, the DELETE of 1.5 on n2 removes both rows of rep.r05_child');
CALL ref_meta.reg('R5', 'rep.r05_child', 'rows 1, 2 changed by text (1.50 / 1.5)');

-- R7: keys for a repair plan written by hand.
CREATE TABLE rep.r07_text_keys (id text PRIMARY KEY, v text);
INSERT INTO rep.r07_text_keys VALUES ('same', 'x');
\if :n1
INSERT INTO rep.r07_text_keys VALUES ('1.50', 'n1'), ('1.5', 'n1'), ('007', 'n1'), ('7', 'n1'), ('true', 'n1'), ('t', 'n1'), ('null', 'n1'), ('1e3', 'n1'), ('0x10', 'n1'), ('2026-01-01', 'n1'), ('yes', 'n1'), ('~', 'n1');
\else
INSERT INTO rep.r07_text_keys VALUES ('1.50', 'n2'), ('1.5', 'n2'), ('007', 'n2'), ('7', 'n2'), ('true', 'n2'), ('t', 'n2'), ('null', 'n2'), ('1e3', 'n2'), ('0x10', 'n2'), ('2026-01-01', 'n2'), ('yes', 'n2'), ('~', 'n2');
\endif
CALL ref_meta.reg('R7', 'rep.r07_text_keys', '12 keys changed; a plan that names one key (1.50, 007, true, null, 1e3, 0x10, yes, ~) must touch this key only');

-- R8: values for coalesce_priority.
CREATE TABLE rep.r08_coalesce (id int PRIMARY KEY, a text, b text);
\if :n1
INSERT INTO rep.r08_coalesce VALUES (1, 'n1a', NULL), (2, NULL, 'n1b'), (3, 'n1a', 'n1b');
\else
INSERT INTO rep.r08_coalesce VALUES (1, 'n2a', 'n2b'), (2, 'n2a', NULL), (3, 'n2a', 'n2b');
\endif
CALL ref_meta.reg('R8', 'rep.r08_coalesce', '3 changed rows; coalesce_priority [n1, n2] gives (n1a, n2b), (n2a, n1b), (n1a, n1b)');

-- R9: unique values swapped between rows.
CREATE TABLE rep.r09_unique_swap (id int PRIMARY KEY, u text UNIQUE);
\if :n1
INSERT INTO rep.r09_unique_swap VALUES (1, 'A'), (2, 'B'), (3, 'X'), (4, 'Y'), (5, 'Z'), (6, 'same');
\else
INSERT INTO rep.r09_unique_swap VALUES (1, 'B'), (2, 'A'), (3, 'Y'), (4, 'Z'), (5, 'X'), (6, 'same');
\endif
CALL ref_meta.reg('R9', 'rep.r09_unique_swap', '5 changed rows (a swap of two and a cycle of three). Row by row UPDATE hits the unique index: the repair cannot converge without a deferred check or a delete and insert');
CALL ref_meta.reg('V5', 'rep.r09_unique_swap', 'values swapped between keys must be found');

-- R10: foreign keys between tables and inside one table.
CREATE TABLE rep.r10_parent (id int PRIMARY KEY, v text);
CREATE TABLE rep.r10_child (id int PRIMARY KEY, parent_id int REFERENCES rep.r10_parent, v text);
CREATE TABLE rep.r10_tree (id int PRIMARY KEY, parent_id int REFERENCES rep.r10_tree, v text);
INSERT INTO rep.r10_parent VALUES (1, 'same');
INSERT INTO rep.r10_child VALUES (1, 1, 'same');
INSERT INTO rep.r10_tree VALUES (100, NULL, 'root');
\if :n1
INSERT INTO rep.r10_parent VALUES (2, 'only n1');
INSERT INTO rep.r10_child VALUES (2, 2, 'only n1, needs parent 2');
INSERT INTO rep.r10_tree VALUES (10, 100, 'only n1'), (5, 10, 'only n1, its parent has a greater key'), (1, 5, 'only n1');
\else
INSERT INTO rep.r10_parent VALUES (3, 'only n2');
INSERT INTO rep.r10_child VALUES (3, 3, 'only n2, child of parent 3');
\endif
CALL ref_meta.reg('R10', 'rep.r10_parent', 'row 2 only on n1, row 3 only on n2. Repair of this table alone deletes parent 3 on n2 while its child stays: no error when FK triggers do not fire');
CALL ref_meta.reg('R10', 'rep.r10_child', 'row 2 only on n1, row 3 only on n2. Repair of this table alone inserts child 2 without its parent');
CALL ref_meta.reg('R10', 'rep.r10_tree', 'rows 1, 5, 10 only on n1. When the repair fires triggers, the inserts in key order (1, 5, 10) fail: each row points to a row with a greater key');

-- R11: an exclusion constraint.
CREATE TABLE rep.r11_exclusion (id int PRIMARY KEY, room int, during int4range, EXCLUDE USING gist (room WITH =, during WITH &&));
\if :n1
INSERT INTO rep.r11_exclusion VALUES (1, 1, '[1,5)'), (2, 1, '[5,9)'), (3, 2, '[1,5)');
\else
INSERT INTO rep.r11_exclusion VALUES (1, 1, '[5,9)'), (2, 1, '[1,5)'), (3, 2, '[1,5)');
\endif
CALL ref_meta.reg('R11', 'rep.r11_exclusion', 'rows 1, 2 changed (ranges swapped): a single-row UPDATE violates the exclusion constraint');

-- R12: the target has no partition for the row.
CREATE TABLE rep.r12_part (id int, region text, v text, PRIMARY KEY (id, region)) PARTITION BY LIST (region);
CREATE TABLE rep.r12_part_eu PARTITION OF rep.r12_part FOR VALUES IN ('eu');
INSERT INTO rep.r12_part VALUES (1, 'eu', 'same');
\if :n1
CREATE TABLE rep.r12_part_us PARTITION OF rep.r12_part FOR VALUES IN ('us');
INSERT INTO rep.r12_part VALUES (2, 'us', 'only n1, no partition on n2'), (3, 'eu', 'only n1');
\endif
CALL ref_meta.reg('R12', 'rep.r12_part', 'rows (2, us) and (3, eu) only on n1. Repair: row 2 fails on n2 (no partition of relation found for row), row 3 is applied');
