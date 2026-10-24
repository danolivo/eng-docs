-- Visibility map coverage of the benchmark tables, with an assertion.
--
--   psql -f vm-check.sql                      fail if any table is below 0.99
--   psql -v min_vm=0 -f vm-check.sql          report only (degraded runs)
--   psql -v tables='^wide$' -f vm-check.sql   other set of tables (regex)
--
-- Run it on both nodes after finish.sql and again before every series.
-- Record vm_frac of every table in the results of each run.
--
-- pg_class.relallvisible is what the planner uses (cost of an Index Only Scan
-- depends on relallvisible / relpages); it is refreshed by VACUUM and ANALYZE
-- only. If the pg_visibility extension is installed, the script also counts
-- the bits in the map itself and asserts on those exact numbers.
\set ON_ERROR_STOP 1
\if :{?min_vm}
\else
  \set min_vm 0.99
\endif
\if :{?tables}
\else
  \set tables '^(narrow|wide|toast)(_(rk|sk|id))?$'
\endif

SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_visibility') AS has_vis \gset

\echo '-- planner view (pg_class)'
SELECT c.relname, c.relpages, c.relallvisible,
       round(c.relallvisible::numeric / nullif(c.relpages, 0), 4) AS vm_frac,
       c.reltuples::bigint AS rows
  FROM pg_class c
 WHERE c.relkind = 'r' AND c.relname ~ :'tables'
 ORDER BY 1;

\if :has_vis
\echo '-- the map itself (pg_visibility_map_summary)'
SELECT c.relname, pg_relation_size(c.oid) / current_setting('block_size')::int AS pages,
       s.all_visible, s.all_frozen,
       round(s.all_visible::numeric
             / nullif(pg_relation_size(c.oid) / current_setting('block_size')::int, 0), 4) AS vm_frac
  FROM pg_class c, LATERAL pg_visibility_map_summary(c.oid) s
 WHERE c.relkind = 'r' AND c.relname ~ :'tables'
 ORDER BY 1;
SELECT count(*) = 0 AS vm_ok
  FROM pg_class c, LATERAL pg_visibility_map_summary(c.oid) s
 WHERE c.relkind = 'r' AND c.relname ~ :'tables'
   AND pg_relation_size(c.oid) > 0
   AND s.all_visible::float8 / (pg_relation_size(c.oid) / current_setting('block_size')::int) < :min_vm \gset
\else
SELECT count(*) = 0 AS vm_ok
  FROM pg_class c
 WHERE c.relkind = 'r' AND c.relname ~ :'tables'
   AND c.relpages > 0 AND c.relallvisible::float8 / c.relpages < :min_vm \gset
\endif

\if :vm_ok
  \echo 'vm-check: OK, threshold' :min_vm
\else
  \echo 'vm-check: visibility map coverage below' :min_vm
  DO $$ BEGIN RAISE EXCEPTION 'visibility map coverage below threshold: run finish.sql with no xmin holders'; END $$;
\endif
