-- Case P18: the Merkle tree objects of a table travel with a dump.
-- Stand: node 1 is a database where mtree works. Node 2 does not exist yet:
--        it is made from a dump of node 1.
-- Run:   1. node 1 script in the node 1 database; then mtree init and
--           mtree build for sp.p18_tree_table on node 1;
--        2. make node 2 from node 1:
--             createdb n2
--             pg_dump -Fc -d n1 | pg_restore -d n2
--        3. node 2 script in the new database: it changes rows after the
--           restore, as an application would;
--        4. mtree table-diff (without and with mtree update) and a plain
--           table-diff of sp.p18_tree_table.
-- Expect: rows 100, 5000, 9999 changed, row 7777 only on node 1, row 10001
--         only on node 2. The dump carried the tree tables of the pgedge_ace
--         schema and the publication, but no replication slot: the tree of
--         node 2 knows nothing about the changes of step 3. mtree must refuse
--         the stale tree or rebuild it; it must not answer "match" from the
--         old hashes.
\if :n1
DROP TABLE IF EXISTS sp.p18_tree_table;
CREATE TABLE sp.p18_tree_table (id int PRIMARY KEY, v text);
INSERT INTO sp.p18_tree_table SELECT i, 'v' || i FROM generate_series(1, 10000) i;
COMMENT ON TABLE sp.p18_tree_table IS 'P18: after the steps of the header: 3 changed rows, 1 row only on node 1, 1 row only on node 2';
\else
UPDATE sp.p18_tree_table SET v = 'changed after the restore' WHERE id IN (100, 5000, 9999);
DELETE FROM sp.p18_tree_table WHERE id = 7777;
INSERT INTO sp.p18_tree_table VALUES (10001, 'new after the restore');
\endif
