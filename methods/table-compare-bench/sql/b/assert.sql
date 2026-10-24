-- Family B, step 8 (n1 and n2, after common/finish.sql): sizes and shape asserts.
-- narrow and wide must not be TOASTed, wide rows ~256 B, toast rows ~3,000 B
-- logical with the payload stored out of line (>= 2 chunks per row).
\set ON_ERROR_STOP 1
SELECT c.relname, c.reltuples::bigint AS rows,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_relation_size(c.reltoastrelid)) AS toast,
       (SELECT reltuples::bigint FROM pg_class WHERE oid = c.reltoastrelid) AS toast_tuples,
       pg_size_pretty(pg_indexes_size(c.oid)) AS idx
  FROM pg_class c
 WHERE c.relkind = 'r' AND c.relname ~ '^(narrow|wide|toast)_(rk|sk|id)$'
 ORDER BY 1;
DO $$
DECLARE t text; w float8; tt float8; tr float8; ts bigint;
BEGIN
  FOR t IN SELECT relname FROM pg_class WHERE relkind = 'r' AND relname ~ '^(narrow|wide)_(rk|sk|id)$' LOOP
    SELECT pg_relation_size(reltoastrelid) INTO ts FROM pg_class WHERE relname = t;
    IF ts > 0 THEN RAISE EXCEPTION '% is TOASTed: % bytes', t, ts; END IF;
    EXECUTE format('SELECT avg(pg_column_size(x.*)) FROM (SELECT * FROM %I LIMIT 100000) x', t) INTO w;
    IF w IS NULL THEN RAISE EXCEPTION '%: empty', t; END IF;
    RAISE NOTICE '%: avg row % B, toast 0', t, round(w::numeric, 1);
    IF t ~ '^wide' AND (w < 240 OR w > 272) THEN RAISE EXCEPTION '%: avg row % B, want ~256', t, w; END IF;
  END LOOP;
  FOR t IN SELECT relname FROM pg_class WHERE relkind = 'r' AND relname ~ '^toast_(rk|sk|id)$' LOOP
    EXECUTE format('SELECT avg(pg_column_size(x.*) - pg_column_size(x.payload) + octet_length(x.payload))
                      FROM (SELECT * FROM %I LIMIT 10000) x', t) INTO w;
    IF w IS NULL THEN RAISE EXCEPTION '%: empty', t; END IF;
    SELECT c.reltuples, tc.reltuples INTO tr, tt FROM pg_class c JOIN pg_class tc ON tc.oid = c.reltoastrelid
     WHERE c.relname = t;
    RAISE NOTICE '%: logical row % B, % rows, % chunks', t, round(w::numeric, 1), tr, tt;
    IF w < 2900 OR w > 3100 THEN RAISE EXCEPTION '%: logical row % B, want ~3000', t, w; END IF;
    IF tt < 1.9 * tr THEN RAISE EXCEPTION '%: % chunks for % rows, payload not out of line', t, tt, tr; END IF;
  END LOOP;
END $$;
