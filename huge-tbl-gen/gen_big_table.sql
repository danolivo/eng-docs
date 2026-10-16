--
-- gen_big_table.sql -- (re)generate a wide synthetic table.
--
-- 3 000 000 000 rows, 440 GB as PostgreSQL reports it (\dt+,
-- pg_relation_size), no indexes, random data. PostgreSQL >= 17.
--
--   psql -d <db> -f gen_big_table.sql
--
-- Size: every row is a 145..152-byte tuple, MAXALIGNed to 152, so exactly
-- 52 rows fit an 8 kB page: 3e9 / 52 * 8192 = 440.16 GiB. That holds because
-- each value has a fixed on-disk width (numerics with a fixed number of
-- digit groups, short fixed-length texts, date right after the uuids so it
-- needs no padding, no NULLs). Size scales linearly with the row count in
-- generate_series().
--
-- One session, one transaction: ~0.25-0.3 M rows/s, i.e. about 3 hours. If
-- it is interrupted, everything rolls back; just run the file again.
-- With wal_level = minimal the INSERT writes no WAL at all, because the
-- table is created in the same transaction.
--

BEGIN;

DROP TABLE IF EXISTS big_table;

CREATE TABLE big_table (
    id              uuid          NOT NULL,
    parent_id       uuid          NOT NULL,
    correlation_id  uuid          NOT NULL,
    event_date      date          NOT NULL,  -- keep right after the uuids: no padding
    amount          numeric(15,2) NOT NULL,  -- 10000.01 .. 99999999.99, 9 bytes
    amount_net      numeric(15,2) NOT NULL,  -- same, 9 bytes
    price           numeric(12,2) NOT NULL,  -- 1.01 .. 9999.99, 7 bytes
    unit_cost       numeric(12,2) NOT NULL,  -- same, 7 bytes
    qty             numeric(10,0) NOT NULL,  -- 1 .. 9999, 5 bytes
    qty_shipped     numeric(10,0) NOT NULL,  -- same, 5 bytes
    tax_rate        numeric(6,4)  NOT NULL,  -- 0.0001 .. 0.9999, 5 bytes
    discount_rate   numeric(6,4)  NOT NULL,  -- same, 5 bytes
    code            text          NOT NULL,  -- 8 hex chars
    currency        text          NOT NULL,  -- 3 chars, 10 values
    status          text          NOT NULL,  -- 3..4 chars, 6 values
    region          text          NOT NULL   -- 2 chars, 8 values
);

-- uuid = two random int8 with the v4 version/variant bits set: ~2.5x cheaper
-- than gen_random_uuid(). Numerics are built from integers: float -> numeric
-- is ~6x slower. generate_series() is in a target list, not in FROM, so the
-- 3e9 row numbers are streamed rather than materialised in a temp file.
INSERT INTO big_table
SELECT
    (lpad(to_hex((random(-9223372036854775808, 9223372036854775807) & ~61440::int8) | 16384::int8), 16, '0')
     || to_hex((random(-9223372036854775808, 9223372036854775807) & 4611686018427387903::int8) | (-9223372036854775808)::int8))::uuid,
    (lpad(to_hex((random(-9223372036854775808, 9223372036854775807) & ~61440::int8) | 16384::int8), 16, '0')
     || to_hex((random(-9223372036854775808, 9223372036854775807) & 4611686018427387903::int8) | (-9223372036854775808)::int8))::uuid,
    (lpad(to_hex((random(-9223372036854775808, 9223372036854775807) & ~61440::int8) | 16384::int8), 16, '0')
     || to_hex((random(-9223372036854775808, 9223372036854775807) & 4611686018427387903::int8) | (-9223372036854775808)::int8))::uuid,
    date '2015-01-01' + random(0, 4017),
    random(1000001, 9999999999)::numeric * 0.01,
    random(1000001, 9999999999)::numeric * 0.01,
    random(101, 999999)::numeric * 0.01,
    random(101, 999999)::numeric * 0.01,
    random(1, 9999)::numeric,
    random(1, 9999)::numeric,
    random(1, 9999)::numeric * 0.0001,
    random(1, 9999)::numeric * 0.0001,
    lpad(to_hex(random(0, 4294967295)), 8, '0'),
    (ARRAY['USD','EUR','GBP','JPY','CHF','CAD','AUD','CNY','SEK','NOK'])[random(1, 10)],
    (ARRAY['new','open','paid','sent','held','void'])[random(1, 6)],
    (ARRAY['EU','US','UK','JP','BR','IN','CA','AU'])[random(1, 8)]
FROM (SELECT generate_series(1, 3000000000)) AS s;

COMMIT;

-- Optional: sets hint bits and freezes every page once (~40 min for 440 GB),
-- so the first scans afterwards don't rewrite the whole table themselves.
VACUUM (FREEZE, ANALYZE) big_table;

SELECT pg_size_pretty(pg_relation_size('big_table')) AS heap,
       pg_size_pretty(pg_table_size('big_table'))    AS table_size,
       round(reltuples::numeric / relpages, 2)       AS rows_per_page
FROM pg_class WHERE oid = 'big_table'::regclass;
