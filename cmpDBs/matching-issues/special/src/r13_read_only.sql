-- Case R13: the target of a repair cannot be written.
-- Stand: any two databases. USE A SEPARATE DATABASE for node 2: its script
--        makes that database read-only for new sessions. To undo it, run
--        r13_read_only_undo.sql there.
-- Run:   node 1 and node 2 scripts in the two databases, then diff, then a
--        repair from node 1 to node 2.
-- Expect: the diff works (row 2 changed, rows 3-1000 only on node 1). The
--         repair fails with "cannot execute INSERT in a read-only transaction":
--         one clear error for the node, not 998 failed rows, and no "success".
--         The same must hold for a node in recovery (a physical standby).
DROP TABLE IF EXISTS sp.r13_read_only;
CREATE TABLE sp.r13_read_only (id int PRIMARY KEY, v text);
INSERT INTO sp.r13_read_only VALUES (1, 'same');
\if :n1
INSERT INTO sp.r13_read_only SELECT i, 'v' || i FROM generate_series(2, 1000) i;
\else
INSERT INTO sp.r13_read_only VALUES (2, 'changed');
\endif
COMMENT ON TABLE sp.r13_read_only IS 'R13: row 2 changed, rows 3-1000 only on node 1; node 2 is read-only';
\if :n2
DO $$ BEGIN EXECUTE format('ALTER DATABASE %I SET default_transaction_read_only = on', current_database()); END $$;
\endif
