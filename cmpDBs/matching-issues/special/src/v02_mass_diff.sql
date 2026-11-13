-- Case V2: a difference of about a million rows must be counted in full.
-- Stand: any two databases (for mtree: a stand where the Merkle tree can be
--        built). About 100 MB for each node.
-- Run:   node 1 and node 2 scripts; then table-diff and mtree table-diff.
-- Expect: sp.v02_all_changed: 1000000 changed rows. sp.v02_half_missing:
--         500000 rows only on node 1. The verdict and the summary show these
--         numbers, or say plainly that the report was cut at max_diff_rows.
--         A report with a few rows and no such note is the bug of this case;
--         a repair from such a report must not delete the rows that it did
--         not list.
DROP TABLE IF EXISTS sp.v02_all_changed, sp.v02_half_missing;
CREATE TABLE sp.v02_all_changed (id int PRIMARY KEY, v text);
CREATE TABLE sp.v02_half_missing (id int PRIMARY KEY, v text);
\if :n1
INSERT INTO sp.v02_all_changed SELECT i, 'v' || i FROM generate_series(1, 1000000) i;
INSERT INTO sp.v02_half_missing SELECT i, 'v' || i FROM generate_series(1, 1000000) i;
\else
INSERT INTO sp.v02_all_changed SELECT i, 'w' || i FROM generate_series(1, 1000000) i;
INSERT INTO sp.v02_half_missing SELECT i, 'v' || i FROM generate_series(2, 1000000, 2) i;
\endif
COMMENT ON TABLE sp.v02_all_changed IS 'V2: 1000000 changed rows';
COMMENT ON TABLE sp.v02_half_missing IS 'V2: 500000 rows only on node 1';
