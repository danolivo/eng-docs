-- Family B, step 4 (n1 and n2): build one key variant of one shape.
--
--   psql -v shape=narrow|wide|toast -v variant=rk|sk|id -f build.sql
--
-- Key variants (the same columns and data in all of them):
--   rk  PRIMARY KEY (r numeric, h text, id numeric)  first key column is random
--   sk  PRIMARY KEY (id numeric, r numeric, h text)  first key column is serial
--   id  PRIMARY KEY (id bigserial)                    single integer key
--
-- Rows are inserted ORDER BY id, so the heap follows id on both nodes:
-- correlation(id) = 1, correlation(r) ~ 0. For rk, any read in key order
-- visits the heap in random order. Sessions for different (shape, variant)
-- pairs can run in parallel.
\set ON_ERROR_STOP 1
SET synchronize_seqscans = off;

SELECT :'shape' IN ('narrow', 'wide', 'toast') AND :'variant' IN ('rk', 'sk', 'id') AS ok \gset
\if :ok
\else
  \echo 'usage: psql -v shape=narrow|wide|toast -v variant=rk|sk|id -f build.sql'
  \quit
\endif

WITH p AS (
  SELECT format('%s_%s', :'shape', :'variant') AS t,
         'base_' || :'shape' AS base,
         CASE :'variant' WHEN 'id' THEN 'bigserial' ELSE 'numeric NOT NULL' END AS idt,
         CASE :'variant' WHEN 'rk' THEN 'r, h, id' WHEN 'sk' THEN 'id, r, h' ELSE 'id' END AS pk,
         CASE :'shape' WHEN 'wide' THEN 'pad' WHEN 'toast' THEN 'payload' END AS extra
)
SELECT stmt FROM p, LATERAL (VALUES
  (1, format('DROP TABLE IF EXISTS %I', t)),
  (2, format('CREATE TABLE %I (r numeric NOT NULL, h text NOT NULL, id %s, v bigint%s)',
             t, idt, coalesce(', ' || extra || ' text', ''))),
  (3, CASE WHEN extra = 'payload'
           THEN format('ALTER TABLE %I ALTER COLUMN payload SET STORAGE EXTERNAL', t) END),
  (4, format('INSERT INTO %I SELECT r, h, id, v%s FROM %I ORDER BY id',
             t, coalesce(', ' || extra, ''), base)),
  (5, format('ALTER TABLE %I ADD PRIMARY KEY (%s)', t, pk)),
  (6, CASE WHEN :'variant' = 'id'
           THEN format('SELECT setval(pg_get_serial_sequence(%L, %L), (SELECT max(id) FROM %I))',
                       t, 'id', base) END)
) s(n, stmt)
WHERE stmt IS NOT NULL
ORDER BY n
\gexec
