-- Family A, optional (test instance only, after diffs.sql, before finish.sql):
-- many differences in one table, to measure how a tool scales with their count
-- and their spread.
--
--   psql -v tbl=narrow -v mode=scatter -v frac=0.0001 -f diffs-density.sql
--   psql -v tbl=wide   -v mode=chunk   -v frac=0.05   -f diffs-density.sql
--
--   scatter  every (1/frac)-th key, spread over the whole key range: almost
--            every block of a block-hashing tool becomes a mismatch
--   chunk    frac of the key range as one contiguous run starting right after
--            the middle key (rows/2 + 1, so spot-check.sql ids stay intact):
--            the same number of rows, but only the blocks that cover it mismatch
--
-- -v rows=N must match the ROWS used for loading (default 100000000).
--
-- The change is the last digit of a numeric column (narrow.n2, wide.u3,
-- toast.p1), the cheapest change to apply and to detect. Rows already listed
-- in gt are skipped, so the expected total is gt_density.n + 10.
-- Run finish.sql afterwards: the updates clear the visibility map bits of
-- every touched page.
\set ON_ERROR_STOP 1
\if :{?rows}
\else
  \set rows 100000000
\endif
SELECT :'tbl' IN ('narrow', 'wide', 'toast') AND :'mode' IN ('scatter', 'chunk')
       AND :frac > 0 AND :frac <= 0.5 AS ok \gset
\if :ok
\else
  \echo 'usage: psql -v tbl=narrow|wide|toast -v mode=scatter|chunk -v frac=0.0001 -f diffs-density.sql'
  \quit
\endif

SELECT CASE :'tbl' WHEN 'narrow' THEN 'n2' WHEN 'wide' THEN 'u3' ELSE 'p1' END AS col,
       CASE :'tbl' WHEN 'wide' THEN '0.000000000001' ELSE '0.00000001' END AS delta,
       greatest(round(1 / :frac)::bigint, 1) AS step \gset

CREATE TABLE IF NOT EXISTS gt_density (tbl text, mode text, frac float8, n bigint,
                                       applied_at timestamptz DEFAULT now());

BEGIN;
WITH u AS (
  UPDATE :"tbl" x SET :"col" = :"col" + :delta
   WHERE CASE :'mode'
           WHEN 'scatter' THEN x.id % :step = :step / 2
           ELSE x.id > :rows / 2 AND x.id <= :rows / 2 + round(:rows * :frac)
         END
     AND NOT EXISTS (SELECT 1 FROM gt WHERE gt.tbl = :'tbl' AND gt.id = x.id)
  RETURNING 1
)
INSERT INTO gt_density (tbl, mode, frac, n) SELECT :'tbl', :'mode', :frac, count(*) FROM u;
COMMIT;

SELECT * FROM gt_density ORDER BY applied_at;
