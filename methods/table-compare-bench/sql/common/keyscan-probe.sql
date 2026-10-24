-- Probe: one ordered pass over the primary key, as a slicer does it.
--
--   psql -v tbl=narrow -f keyscan-probe.sql
--   psql -v tbl=narrow_rk -v every=100000 -f keyscan-probe.sql
--
-- Reads only the key columns in key order and keeps every N-th key, the
-- pattern of the pgcmp slicer cursor. The expected plan is an Index Only Scan
-- on the primary key. Look at two lines of the output:
--   Heap Fetches  ~0 on a vacuumed table; on a table with a poor visibility
--                 map it approaches the number of rows on not-all-visible pages
--   Buffers       shared hit + read; with an uncorrelated key every heap fetch
--                 lands on a random heap page
-- If the plan is not an Index Only Scan, the planner has already reacted to a
-- low relallvisible / relpages: note it, this is part of the result.
\set ON_ERROR_STOP 1
\if :{?every}
\else
  \set every 100000
\endif

SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord) AS pkcols
  FROM pg_index i
       CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
 WHERE i.indrelid = :'tbl'::regclass AND i.indisprimary \gset

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT count(*) FROM (
  SELECT row_number() OVER (ORDER BY :pkcols) AS rn FROM :"tbl"
) s
WHERE rn % :every = 0;
