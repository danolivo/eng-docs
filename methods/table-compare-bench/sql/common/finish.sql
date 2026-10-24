-- Final step for both families, on every node, after loading, building and
-- applying the differences: freeze, analyze, checkpoint.
--
-- VACUUM can mark a page all-visible (and all-frozen) only if every tuple on it
-- is visible to every running transaction. Any snapshot that is older than the
-- load keeps the freshly inserted pages out of the visibility map, and with
-- autovacuum = off nobody fixes that later. So the script refuses to run while
-- something holds the xmin horizon back: another session with a snapshot or an
-- open transaction (a parallel load still running, an idle psql in BEGIN),
-- a prepared transaction or a replication slot.
--
-- INDEX_CLEANUP ON is not optional. Since PostgreSQL 14, VACUUM skips index
-- vacuuming when fewer than 2% of the heap pages have dead items. The dead
-- line pointers then stay in the heap, and those pages are not marked
-- all-visible. That is exactly the state after diffs.sql: a few deletes and
-- non-HOT updates on a large table. ON forces the second pass.
--
-- Afterwards, run vm-check.sql: coverage must be 100%.
\set ON_ERROR_STOP 1

SELECT 'session' AS kind, pid::text AS who, datname, state,
       backend_xmin::text AS xmin, now() - xact_start AS xact_age, left(query, 60) AS query
  FROM pg_stat_activity
 WHERE pid <> pg_backend_pid() AND (backend_xmin IS NOT NULL OR backend_xid IS NOT NULL)
UNION ALL
SELECT 'prepared', gid, database, NULL, transaction::text, now() - prepared, NULL
  FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, database, NULL, coalesce(xmin, catalog_xmin)::text, NULL, NULL
  FROM pg_replication_slots
 WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL;

DO $$
DECLARE n int;
BEGIN
  SELECT (SELECT count(*) FROM pg_stat_activity
           WHERE pid <> pg_backend_pid() AND (backend_xmin IS NOT NULL OR backend_xid IS NOT NULL))
       + (SELECT count(*) FROM pg_prepared_xacts)
       + (SELECT count(*) FROM pg_replication_slots WHERE xmin IS NOT NULL OR catalog_xmin IS NOT NULL)
    INTO n;
  IF n > 0 THEN
    RAISE EXCEPTION '% holder(s) of the xmin horizon (listed above): VACUUM would leave pages out of the visibility map', n;
  END IF;
END $$;

VACUUM (FREEZE, ANALYZE, INDEX_CLEANUP ON);
CHECKPOINT;
