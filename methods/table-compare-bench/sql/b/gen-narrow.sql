-- Family B, step 2 (n1 only): one slice [:lo, :hi] of base_narrow.
-- Run JOBS sessions in parallel over disjoint slices (see README).
-- Logical row width of the built tables: ~88 B.
\set ON_ERROR_STOP 1
INSERT INTO base_narrow
SELECT g, random()::numeric, md5(random()::text), (random() * 4.6e18)::bigint
  FROM generate_series(:lo::bigint, :hi::bigint) g;
