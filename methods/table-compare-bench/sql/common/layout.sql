-- Physical layout of the benchmark tables: sizes and how well each primary key
-- column follows the heap order (pg_stats.correlation, needs ANALYZE).
-- Record this together with vm-check.sql output for every series.
--
--   family A, JOBS=16: correlation(id) ~ 0.06 (16 key ranges interleaved)
--   family A, JOBS=1 : correlation(id) ~ 1
--   family B         : correlation(id) = 1, correlation(r) ~ 0
\set ON_ERROR_STOP 1
\if :{?tables}
\else
  \set tables '^(narrow|wide|toast)(_(rk|sk|id))?$'
\endif

SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(coalesce(pg_relation_size(nullif(c.reltoastrelid, 0)), 0)) AS toast,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       k.ord AS key_pos, a.attname AS key_col, round(st.correlation::numeric, 3) AS correlation
  FROM pg_class c
       JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
       CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
       JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
       LEFT JOIN pg_stats st ON st.schemaname = c.relnamespace::regnamespace::name
                            AND st.tablename = c.relname AND st.attname = a.attname
 WHERE c.relkind = 'r' AND c.relname ~ :'tables'
 ORDER BY c.relname, k.ord;
