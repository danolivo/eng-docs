-- Family B, step 2 (n1 only): one slice [:lo, :hi] of base_wide.
-- pad is 164 characters: logical row ~256 B, never TOASTed.
\set ON_ERROR_STOP 1
INSERT INTO base_wide
SELECT g, random()::numeric, md5(random()::text), (random() * 4.6e18)::bigint,
       substr(repeat(md5(random()::text), 6), 1, 164)
  FROM generate_series(:lo::bigint, :hi::bigint) g;
