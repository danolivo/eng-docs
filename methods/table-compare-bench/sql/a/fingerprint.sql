-- Full fingerprint of each table: row count, key range and the sum of a
-- 64-bit hash of every row's text. Run on two instances and compare the
-- output: equal lines mean equal tables. Reads every table in full
-- (~380 GB with toast), so expect it to take a while.
--
-- reference vs test: each table differs in exactly 10 rows (see table gt on
-- the test instance), so all three lines differ there.
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, YMD';
SET extra_float_digits = 1;
SET max_parallel_workers_per_gather = 8;
SELECT 'narrow' AS tbl, count(*), min(id), max(id), sum(hashtextextended(t::text, 0)) AS fingerprint FROM narrow t
UNION ALL
SELECT 'wide', count(*), min(id), max(id), sum(hashtextextended(t::text, 0)) FROM wide t
UNION ALL
SELECT 'toast', count(*), min(id), max(id), sum(hashtextextended(t::text, 0)) FROM toast t;
