-- Family A, test instance only (n2), after diffs.sql and spot-check.sql:
-- many differing rows in one table, to measure how a tool scales with their
-- number and their position in the key range (method, section 3.3).
--
--   psql -v tbl=wide -v mode=scatter -v frac=0.05 -f diffs-density.sql           apply
--   psql -v tbl=wide -v mode=scatter -v frac=0.05 -v undo=1 -f diffs-density.sql restore
--
--   scatter  every (1/frac)-th key over the whole key range: with 1% or more,
--            every block of a block-hashing tool mismatches
--   head     the first frac of the key range: ids 1 .. rows * frac
--   tail     the last frac of the key range: ids rows * (1 - frac) + 1 .. rows
--   chunk    frac of the key range right after the middle key (rows/2 + 1)
--
-- head, tail and chunk are positions in KEY order. With JOBS=16 the heap
-- holds 16 key ranges side by side, so these rows are not at the start or
-- the end of the heap.
--
-- -v rows=N must match the ROWS used for loading (default 100000000).
--
-- The change is the last digit of a numeric column (narrow.n2, wide.u3,
-- toast.p1). Rows listed in gt are skipped, so the expected result is
-- gt + the rows that match the rule in gt_density:
--   lo <= id <= hi AND id % step = step / 2   (step = 1 for head, tail, chunk)
--
-- Only one level per table can be applied at a time: undo the level before
-- the next one. undo subtracts the same delta (exact for numeric), checks
-- that every touched row equals its load formula again and rebuilds the
-- primary key, which the non-HOT updates have bloated. The heap keeps the
-- moved rows: record layout.sql for every level.
--
-- Run finish.sql after apply and after undo: the updates clear the
-- visibility map bits of every touched page.
\set ON_ERROR_STOP 1
\if :{?rows}
\else
  \set rows 100000000
\endif
\if :{?undo}
\else
  \set undo 0
\endif
SELECT CASE WHEN :'undo'::bool THEN '-' ELSE '+' END AS sign,
       :'tbl' || '_pkey' AS pk \gset
SELECT :'tbl' IN ('narrow', 'wide', 'toast') AND :'mode' IN ('scatter', 'head', 'tail', 'chunk')
       AND :frac > 0 AND :frac <= 0.5 AS ok \gset
\if :ok
\else
  \echo 'usage: psql -v tbl=narrow|wide|toast -v mode=scatter|head|tail|chunk -v frac=0.05 [-v undo=1] -f diffs-density.sql'
  \quit
\endif

SELECT CASE :'tbl' WHEN 'narrow' THEN 'n2' WHEN 'wide' THEN 'u3' ELSE 'p1' END AS col,
       CASE :'tbl' WHEN 'wide' THEN '0.000000000001' ELSE '0.00000001' END AS delta,
       CASE :'tbl'
         WHEN 'narrow' THEN '(hashint8extended(x.id, 2) % 1000000000000000000)::numeric / 100000000'
         WHEN 'wide'   THEN 'round(hashint8extended(x.id, 33)::numeric / 7, 12)'
         ELSE               '(hashint8extended(x.id, 81) % 1000000000000000000)::numeric / 100000000'
       END AS formula,
       round(:rows * :frac)::bigint AS cnt \gset
SELECT CASE :'mode' WHEN 'scatter' THEN greatest(round(1 / :frac)::bigint, 1) ELSE 1 END AS step,
       CASE :'mode' WHEN 'tail' THEN :rows - :cnt + 1 WHEN 'chunk' THEN :rows / 2 + 1 ELSE 1 END AS lo,
       CASE :'mode' WHEN 'head' THEN :cnt WHEN 'chunk' THEN :rows / 2 + :cnt ELSE :rows END AS hi \gset

CREATE TABLE IF NOT EXISTS gt_density (tbl text, mode text, frac float8, n bigint,
                                       applied_at timestamptz DEFAULT now());
ALTER TABLE gt_density ADD COLUMN IF NOT EXISTS rows bigint,
                       ADD COLUMN IF NOT EXISTS lo bigint,
                       ADD COLUMN IF NOT EXISTS hi bigint,
                       ADD COLUMN IF NOT EXISTS step bigint;

-- apply: no other level on this table; undo: exactly this level
SELECT CASE WHEN :'undo'::bool
            THEN (SELECT count(*) FROM gt_density WHERE tbl = :'tbl' AND mode = :'mode'
                     AND frac = :frac AND rows = :rows) = 1
            ELSE (SELECT count(*) FROM gt_density WHERE tbl = :'tbl') = 0
       END AS state_ok \gset
\if :state_ok
\else
  SELECT * FROM gt_density ORDER BY applied_at;
  DO $$ BEGIN RAISE EXCEPTION 'gt_density state does not allow this step (listed above): undo the applied level first, or apply before undo'; END $$;
\endif

BEGIN;
WITH u AS (
  UPDATE :"tbl" x SET :"col" = :"col" :sign :delta
   WHERE x.id BETWEEN :lo AND :hi AND x.id % :step = :step / 2
     AND NOT EXISTS (SELECT 1 FROM gt WHERE gt.tbl = :'tbl' AND gt.id = x.id)
  RETURNING 1
)
SELECT count(*) AS n FROM u \gset
\if :undo
  DELETE FROM gt_density WHERE tbl = :'tbl' AND mode = :'mode' AND frac = :frac AND rows = :rows;
\else
  INSERT INTO gt_density (tbl, mode, frac, n, rows, lo, hi, step)
  VALUES (:'tbl', :'mode', :frac, :n, :rows, :lo, :hi, :step);
\endif
COMMIT;
\echo 'rows changed:' :n

\if :undo
SELECT count(*) = 0 AS restored FROM :"tbl" x
 WHERE x.id BETWEEN :lo AND :hi AND x.id % :step = :step / 2
   AND NOT EXISTS (SELECT 1 FROM gt WHERE gt.tbl = :'tbl' AND gt.id = x.id)
   AND x.:"col" IS DISTINCT FROM :formula \gset
\if :restored
  \echo 'undo: every touched row equals its load formula again'
\else
  DO $$ BEGIN RAISE EXCEPTION 'undo: some touched rows differ from the load formula'; END $$;
\endif
REINDEX INDEX :"pk";
\endif

SELECT * FROM gt_density ORDER BY applied_at;
