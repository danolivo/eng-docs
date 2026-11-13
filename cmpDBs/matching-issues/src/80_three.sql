-- Cases that need a third node (R4, U6) or another database encoding
-- (X3, X10). Node 3 can be a database with the LATIN1 encoding.

-- R4: three nodes.
CREATE TABLE rep.r04_three_nodes (id int PRIMARY KEY, v text);
INSERT INTO rep.r04_three_nodes VALUES (1, 'same');
\if :n1
INSERT INTO rep.r04_three_nodes VALUES (3, 'v3 of n1');
\elif :n2
INSERT INTO rep.r04_three_nodes VALUES (2, 'on n2 and n3'), (3, 'v3 of n2');
\else
INSERT INTO rep.r04_three_nodes VALUES (2, 'on n2 and n3'), (3, 'v3 of n3'), (4, 'only n3');
\endif
CALL ref_meta.reg('R4', 'rep.r04_three_nodes', 'row 2 is missing on n1 and is the same on n2 and n3: one INSERT into n1, not two. Row 3 has three versions. Row 4 only on n3');

-- U6 with three nodes: two donors for one NULL.
CREATE TABLE nul.u06_fix_nulls_three (id int PRIMARY KEY, a text);
\if :n1
INSERT INTO nul.u06_fix_nulls_three VALUES (1, NULL), (2, NULL);
\elif :n2
INSERT INTO nul.u06_fix_nulls_three VALUES (1, 'from n2'), (2, 'same donor');
\else
INSERT INTO nul.u06_fix_nulls_three VALUES (1, 'from n3'), (2, 'same donor');
\endif
CALL ref_meta.reg('U6', 'nul.u06_fix_nulls_three', 'a repair that only fills NULLs, on three nodes: row 1 of n1 has two different donors (the choice must follow a stated rule), row 2 has one value');

-- X3: text that both a UTF8 and a LATIN1 database can hold.
CREATE TABLE txt.x03_encoding (id int PRIMARY KEY, v text);
INSERT INTO txt.x03_encoding VALUES (1, 'plain'), (2, U&'caf\00E9'), (3, U&'na\00EFve'), (4, U&'\00DCn\00EFc\00F6d\00E9'), (5, U&'\00A3 10 \00B1 1');
CALL ref_meta.reg('X3', 'txt.x03_encoding', 'match on all nodes, also when the database encodings differ (UTF8 / LATIN1)');
-- P14: a database restored with another encoding.
CALL ref_meta.reg('P14', 'txt.x03_encoding', 'a database restored with another encoding');

-- X10: text that a LATIN1 database cannot hold.
CREATE TABLE txt.x10_encoding_target (id int PRIMARY KEY, v text);
INSERT INTO txt.x10_encoding_target VALUES (1, 'plain');
\if :n3
\else
INSERT INTO txt.x10_encoding_target VALUES (2, U&'\20AC 100'), (3, U&'\65E5\672C\8A9E'), (4, U&'caf\00E9');
\endif
CALL ref_meta.reg('X10', 'txt.x10_encoding_target', 'n1 and n2 match. Against a LATIN1 node 3: rows 2-4 only on n1; repair into n3 fails for rows 2, 3 (no equivalent in LATIN1) and is applied for row 4');
