-- Case K17: a primary key index that no longer follows the sort rules of its
-- column, as after an OS upgrade without REINDEX.
-- Stand: any two databases; node 1 needs a superuser. USE A SCRATCH DATABASE
--        for node 1: its script edits two catalog rows of its own table by hand
--        (pg_attribute.attcollation, pg_index.indcollation) to get the state
--        that a collation change leaves behind.
-- Run:   node 1 script = the broken side, node 2 script = the healthy side.
-- Expect: both tables hold the same 3000 rows, and node 1 also holds the
--         duplicate keys that its broken unique index let in (the script
--         prints how many). An index scan and a sequential scan of node 1 give
--         different answers:
--           SET enable_seqscan = off;
--           SELECT count(*) FROM sp.k17_broken_index WHERE id >= 'a' AND id < 'n';
--           RESET enable_seqscan; SET enable_indexscan = off; SET enable_bitmapscan = off; -- and again
--         amcheck shows the damage: SELECT bt_index_check('sp.k17_broken_index_pkey');
--         A comparison must not report "match"; rows found twice or not found
--         by key must be reported, not hidden.
DROP TABLE IF EXISTS sp.k17_broken_index;
\if :n1
CREATE TABLE sp.k17_broken_index (id text COLLATE "C" PRIMARY KEY, v text);
\else
CREATE TABLE sp.k17_broken_index (id text COLLATE "en-x-icu" PRIMARY KEY, v text);
\endif
INSERT INTO sp.k17_broken_index
	SELECT CASE WHEN i % 2 = 0 THEN chr(65 + i % 26) ELSE chr(97 + i % 26) END || (ARRAY['-', '+', '_', ''])[1 + i % 4] || lpad(i::text, 5, '0'), 'v' || i
	FROM generate_series(1, 3000) i;
\if :n1
-- The index pages keep the C order; the catalog now says ICU order.
UPDATE pg_attribute SET attcollation = (SELECT oid FROM pg_collation WHERE collname = 'en-x-icu')
	WHERE attname = 'id' AND attrelid IN ('sp.k17_broken_index'::regclass, 'sp.k17_broken_index_pkey'::regclass);
UPDATE pg_index SET indcollation = ((SELECT oid FROM pg_collation WHERE collname = 'en-x-icu')::text)::oidvector
	WHERE indexrelid = 'sp.k17_broken_index_pkey'::regclass;
-- Try to insert every key again. A healthy unique index refuses all of them.
DO $$
DECLARE
	r record;
	dup int := 0;
BEGIN
	FOR r IN SELECT id FROM sp.k17_broken_index ORDER BY v LOOP
		BEGIN
			INSERT INTO sp.k17_broken_index VALUES (r.id, 'duplicate');
			dup := dup + 1;
		EXCEPTION WHEN unique_violation THEN
			NULL;
		END;
	END LOOP;
	RAISE WARNING 'K17: the broken unique index accepted % duplicate keys', dup;
END $$;
\endif
COMMENT ON TABLE sp.k17_broken_index IS 'K17: node 1 has a broken primary key index and duplicate keys; node 2 is healthy';
