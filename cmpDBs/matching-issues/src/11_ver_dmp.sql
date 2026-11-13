-- Verdict: V1, V4, V5, V6. Dump / restore / pg_upgrade scenario: P4 .. P19.

-- V1: one block of the table cannot be read on one node.
CREATE TABLE ver.v01_block_error (id int PRIMARY KEY, d int, q int GENERATED ALWAYS AS (100 / d) VIRTUAL);
INSERT INTO ver.v01_block_error (id, d) SELECT i, 1 FROM generate_series(1, 5000) i;
\if :n2
UPDATE ver.v01_block_error SET d = 0 WHERE id = 2500;
UPDATE ver.v01_block_error SET d = 2 WHERE id = 4000;
\endif
CALL ref_meta.reg('V1', 'ver.v01_block_error', 'on n2 the row 2500 cannot be read (division by zero in a virtual column), so the block with it fails there. The verdict must be an error with an exit code that is not zero, never "match"; row 4000 is a real difference in another block');

-- V6: changes that gave the same text under a row encoding that joined the
-- columns and the rows with a separator.
CREATE TABLE ver.v06_text_collisions (id int PRIMARY KEY, a text, b text);
\if :n1
INSERT INTO ver.v06_text_collisions VALUES (1, NULL, 'y'), (2, 'a|b', 'c'), (3, 'p', 'q'), (4, 'r', 's');
\else
INSERT INTO ver.v06_text_collisions VALUES (1, '', 'y'), (2, 'a', 'b|c'), (3, 'p', 'q|4|r|s');
\endif
CALL ref_meta.reg('V6', 'ver.v06_text_collisions', 'rows 1, 2, 3 changed, row 4 only on n1. A true pair of rows with the same 8-byte hash is not in the set: to find one takes about 2^32 hash computations');

-- V4: long values that differ far from the start.
CREATE TABLE ver.v04_long_value (id int PRIMARY KEY, v text);
\if :n1
INSERT INTO ver.v04_long_value VALUES (1, repeat('a', 3000) || 'X' || repeat('a', 2000)), (2, repeat('b', 1024) || '1'), (3, repeat('c', 100000));
\else
INSERT INTO ver.v04_long_value VALUES (1, repeat('a', 3000) || 'Y' || repeat('a', 2000)), (2, repeat('b', 1024) || '2'), (3, repeat('c', 99999) || 'd');
\endif
CALL ref_meta.reg('V4', 'ver.v04_long_value', '3 changed rows; the values differ at the positions 3001, 1025 and 100000, after the point where an HTML report cuts them');

-- V5: values swapped between two keys.
CREATE TABLE ver.v05_swap (id int PRIMARY KEY, v text);
\if :n1
INSERT INTO ver.v05_swap VALUES (1, 'A'), (2, 'B'), (3, 'C'), (4, 'C');
\else
INSERT INTO ver.v05_swap VALUES (1, 'B'), (2, 'A'), (3, 'C'), (4, 'C');
\endif
CALL ref_meta.reg('V5', 'ver.v05_swap', 'rows 1, 2 changed: the same set of values under other keys');

-- P4: a table that lost all its rows on the restored side.
CREATE TABLE dmp.p04_lost_table (id int PRIMARY KEY, v text);
\if :n1
INSERT INTO dmp.p04_lost_table SELECT i, 'v' || i FROM generate_series(1, 50000) i;
\endif
CALL ref_meta.reg('P4', 'dmp.p04_lost_table', '50000 rows only on n1; n2 is empty');

-- P5: the primary key was not built on the restored side.
\if :n1
CREATE TABLE dmp.p05_key_lost (id int PRIMARY KEY, v text);
INSERT INTO dmp.p05_key_lost VALUES (1, 'a'), (2, 'b'), (3, 'c');
\else
CREATE TABLE dmp.p05_key_lost (id int, v text);
INSERT INTO dmp.p05_key_lost VALUES (1, 'a'), (2, 'b'), (2, 'b again'), (3, 'c');
\endif
CALL ref_meta.reg('P5', 'dmp.p05_key_lost', 'n2 has no primary key and two rows with id 2: the error names the node');

-- P7: columns that hold catalog OIDs.
CREATE TABLE dmp.p07_target (id int PRIMARY KEY);
CREATE TYPE dmp.p07_color AS ENUM ('red', 'green');
CREATE TABLE dmp.p07_catalog_oids (id int PRIMARY KEY, tbl_oid oid, tbl regclass, typ_oid oid, typ regtype);
INSERT INTO dmp.p07_catalog_oids VALUES (1, 'dmp.p07_target'::regclass::oid, 'dmp.p07_target', 'dmp.p07_color'::regtype::oid, 'dmp.p07_color');
CALL ref_meta.reg('P7', 'dmp.p07_catalog_oids', 'tbl and typ are equal by name; tbl_oid and typ_oid differ, because each node gave its own OIDs to the same objects. After a dump and restore the numbers are equal and point to other objects: a "match" that is wrong');

-- P9: hash partitioning on an enum. The hash comes from the OID of the label.
CREATE TYPE dmp.p09_color AS ENUM ('red', 'green', 'blue', 'cyan', 'magenta', 'yellow', 'black', 'white');
CREATE TABLE dmp.p09_hash_enum (e dmp.p09_color, id int, v text, PRIMARY KEY (e, id)) PARTITION BY HASH (e);
CREATE TABLE dmp.p09_hash_enum_0 PARTITION OF dmp.p09_hash_enum FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE dmp.p09_hash_enum_1 PARTITION OF dmp.p09_hash_enum FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE dmp.p09_hash_enum_2 PARTITION OF dmp.p09_hash_enum FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE dmp.p09_hash_enum_3 PARTITION OF dmp.p09_hash_enum FOR VALUES WITH (MODULUS 4, REMAINDER 3);
INSERT INTO dmp.p09_hash_enum SELECT (enum_range(NULL::dmp.p09_color))[1 + i % 8], i, 'v' || i FROM generate_series(1, 800) i;
CALL ref_meta.reg('P9', 'dmp.p09_hash_enum', 'match through the root; the rows can be in other leaves on each node, so a leaf-by-leaf comparison can differ');

-- P10: the column order of an inheritance child after a restore.
CREATE TABLE dmp.p10_parent (id int PRIMARY KEY, a text);
\if :n1
CREATE TABLE dmp.p10_child (c text, PRIMARY KEY (id)) INHERITS (dmp.p10_parent);
ALTER TABLE dmp.p10_parent ADD COLUMN b text;
\else
ALTER TABLE dmp.p10_parent ADD COLUMN b text;
CREATE TABLE dmp.p10_child (c text, PRIMARY KEY (id)) INHERITS (dmp.p10_parent);
\endif
INSERT INTO dmp.p10_parent (id, a, b) VALUES (1, 'a1', 'b1');
INSERT INTO dmp.p10_child (id, a, b, c) VALUES (2, 'a2', 'b2', 'c2'), (3, 'a3', 'b3', 'c3');
CALL ref_meta.reg('P10', 'dmp.p10_child', 'match; the columns are (id, a, c, b) on n1 and (id, a, b, c) on n2');
CALL ref_meta.reg('P10', 'dmp.p10_parent', 'match');

-- P11: a stored generated column whose function gives another result.
\if :n1
CREATE FUNCTION dmp.p11_norm(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT lower($1) $$;
\else
CREATE FUNCTION dmp.p11_norm(text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT upper($1) $$;
\endif
CREATE TABLE dmp.p11_generated (id int PRIMARY KEY, v text, norm text GENERATED ALWAYS AS (dmp.p11_norm(v)) STORED);
INSERT INTO dmp.p11_generated (id, v) VALUES (1, 'Alice'), (2, 'Bob'), (3, '123');
CALL ref_meta.reg('P11', 'dmp.p11_generated', 'rows 1, 2 changed in norm only (alice / ALICE); row 3 equal; the difference cannot be repaired by data');

-- P16: sequences.
CREATE TABLE dmp.p16_seq_tbl (id bigserial PRIMARY KEY, v text);
CREATE SEQUENCE dmp.p16_standalone_seq;
INSERT INTO dmp.p16_seq_tbl (v) VALUES ('a'), ('b'), ('c');
\if :n1
DO $$ BEGIN PERFORM setval('dmp.p16_seq_tbl_id_seq', 1000); PERFORM setval('dmp.p16_standalone_seq', 500); END $$;
\endif
CALL ref_meta.reg('P16', 'dmp.p16_seq_tbl', 'the tables match; the sequences are at 1000 / 3 and 500 / not called. Sequences are not compared');

-- P19: physical differences that must not show.
\if :n1
CREATE TABLE dmp.p19_physical (id int PRIMARY KEY, v text, w text);
INSERT INTO dmp.p19_physical SELECT i, repeat(md5(i::text), 100), 'w' || i FROM generate_series(1, 5000) i;
\else
CREATE TABLE dmp.p19_physical (id int PRIMARY KEY, v text COMPRESSION lz4, w text) WITH (fillfactor = 50);
INSERT INTO dmp.p19_physical SELECT i, repeat(md5(i::text), 100), 'old' FROM generate_series(5000, 1, -1) i;
UPDATE dmp.p19_physical SET w = 'w' || id;
DELETE FROM dmp.p19_physical WHERE id % 10 = 0;
INSERT INTO dmp.p19_physical SELECT i, repeat(md5(i::text), 100), 'w' || i FROM generate_series(10, 5000, 10) i;
\endif
CALL ref_meta.reg('P19', 'dmp.p19_physical', 'match: other compression, fillfactor, row order and dead rows on n2');
