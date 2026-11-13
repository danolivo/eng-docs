-- Case D7: a block whose text is over 1 GB.
-- Stand: any two databases. HEAVY: 300000 rows of 4000 characters; about
--        1.2 GB of row text for each node (much less on disk: the text is
--        compressed), and some minutes of load time.
-- Run:   node 1 and node 2 scripts; then a diff with a block size that is not
--        less than the table: table-diff -b 1000000 ...
-- Expect: rows 1, 150000 and 300000 changed. No "out of memory" (SQLSTATE
--         54000) or "invalid memory alloc request size" from an aggregate over
--         the whole block; if a block cannot be read, an error, never "match".
DROP TABLE IF EXISTS sp.d07_big_block;
CREATE TABLE sp.d07_big_block (id int PRIMARY KEY, v text);
INSERT INTO sp.d07_big_block SELECT i, repeat(md5(i::text), 125) FROM generate_series(1, 300000) i;
\if :n2
UPDATE sp.d07_big_block SET v = repeat(md5(id::text), 124) || md5('changed') WHERE id IN (1, 150000, 300000);
\endif
COMMENT ON TABLE sp.d07_big_block IS 'D7: rows 1, 150000, 300000 changed; one block of this table is over 1 GB of text';
