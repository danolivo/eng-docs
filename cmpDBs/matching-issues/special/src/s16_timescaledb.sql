-- Case S16: a TimescaleDB hypertable whose chunks were made on each node by
-- itself.
-- Stand: two databases on servers with TimescaleDB (the library is in
--        shared_preload_libraries).
-- Run:   node 1 and node 2 scripts.
-- Expect: the hypertable holds the same 2160 rows but 3 changed and 2 only on
--         node 1 (see below). Its chunks cover 1 day on node 1 and 7 days on
--         node 2, so the chunk tables (_timescaledb_internal._hyper_*) have
--         other names and other bounds on each node. A comparison through the
--         hypertable finds the 5 rows. A comparison chunk by chunk cannot pair
--         the chunks: it must say so and must not report thousands of rows.
CREATE EXTENSION IF NOT EXISTS timescaledb;
DROP TABLE IF EXISTS sp.s16_metrics;
CREATE TABLE sp.s16_metrics (ts timestamptz NOT NULL, device int NOT NULL, v float8, PRIMARY KEY (device, ts));
\if :n1
SELECT create_hypertable('sp.s16_metrics', 'ts', chunk_time_interval => interval '1 day');
\else
SELECT create_hypertable('sp.s16_metrics', 'ts', chunk_time_interval => interval '7 days');
\endif
INSERT INTO sp.s16_metrics
	SELECT '2026-01-01 00:00:00+00'::timestamptz + h * interval '1 hour', d, h * d
	FROM generate_series(0, 719) h, generate_series(1, 3) d;
\if :n2
UPDATE sp.s16_metrics SET v = -1 WHERE device = 1 AND ts IN ('2026-01-01 00:00:00+00', '2026-01-07 23:00:00+00', '2026-01-30 23:00:00+00');
DELETE FROM sp.s16_metrics WHERE device = 2 AND ts IN ('2026-01-08 00:00:00+00', '2026-01-15 12:00:00+00');
\endif
COMMENT ON TABLE sp.s16_metrics IS 'S16: 3 changed rows, 2 rows only on node 1; the chunks differ between the nodes';
