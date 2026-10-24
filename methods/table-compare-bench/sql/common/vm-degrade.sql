-- Optional factor: a table with a poor visibility map and the same contents.
--
--   psql -v tbl=narrow -v every=2 -f vm-degrade.sql
--
-- Run AFTER finish.sql (so hint bits are set and the table is frozen), on the
-- side(s) you want to degrade. It performs a no-op update (SET id = id) of the
-- first tuple of every N-th heap page. The contents of the table do not
-- change, but each touched page gets a dead tuple and loses its all-visible
-- bit; the new versions go to the same page (HOT) or to the end of the heap,
-- whose pages are not all-visible either. every = 2 leaves roughly half of the
-- pages all-visible, every = 1 none of them.
--
-- Do not VACUUM afterwards (autovacuum must stay off): that would repair the
-- map. ANALYZE at the end refreshes relallvisible, so the planner sees the
-- degraded state as it would on a production table.
--
-- Side effects to record: about pages/every rows move, so the physical order
-- changes slightly, and the PK index gets one extra entry per moved row.
\set ON_ERROR_STOP 1
\if :{?every}
\else
  \set every 2
\endif

SELECT pg_relation_size(:'tbl') / current_setting('block_size')::int AS npages \gset

UPDATE :"tbl" SET id = id
 WHERE ctid = ANY (ARRAY(
         SELECT format('(%s,1)', p)::tid
           FROM generate_series(0, :npages - 1, :every) AS p));

ANALYZE :"tbl";
CHECKPOINT;

SELECT relname, relpages, relallvisible,
       round(relallvisible::numeric / nullif(relpages, 0), 4) AS vm_frac
  FROM pg_class WHERE oid = :'tbl'::regclass;
