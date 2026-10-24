-- Family B, step 2 (n1 only): one slice [:lo, :hi] of base_toast.
-- payload is 2,912 characters, STORAGE EXTERNAL: logical row ~3,000 B,
-- two TOAST chunks per row.
\set ON_ERROR_STOP 1
INSERT INTO base_toast
SELECT g, random()::numeric, md5(random()::text), (random() * 4.6e18)::bigint,
       repeat(md5(random()::text), 91)
  FROM generate_series(:lo::bigint, :hi::bigint) g;
