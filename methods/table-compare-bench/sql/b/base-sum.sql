-- Family B, step 3 (n1 and n2, after copying): checksum of the base tables.
-- The output must be identical on both nodes before building the variants.
\set ON_ERROR_STOP 1
SET max_parallel_workers_per_gather = 8;
SELECT 'narrow' AS shape, count(*), sum(hashtextextended(b::text, 0) % 1000000007) AS sum FROM base_narrow b
UNION ALL
SELECT 'wide', count(*), sum(hashtextextended(b::text, 0) % 1000000007) FROM base_wide b
UNION ALL
SELECT 'toast', count(*), sum(hashtextextended(b::text, 0) % 1000000007) FROM base_toast b;
