\set ON_ERROR_STOP 1
BEGIN;
DROP TABLE IF EXISTS gt;
CREATE TABLE gt (tbl text, id bigint, cat text, PRIMARY KEY (tbl, id));
INSERT INTO gt VALUES ('narrow', 7000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('narrow', 41000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('narrow', 89000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('narrow', 23000000, 'numeric_cents');
INSERT INTO gt VALUES ('narrow', 67000000, 'numeric_cents');
INSERT INTO gt VALUES ('narrow', 13000000, 'deleted');
INSERT INTO gt VALUES ('narrow', 52000000, 'deleted');
INSERT INTO gt VALUES ('narrow', 97000000, 'deleted');
INSERT INTO gt VALUES ('narrow', 100000001, 'inserted');
INSERT INTO gt VALUES ('narrow', 100000002, 'inserted');
INSERT INTO gt VALUES ('wide', 11000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('wide', 61000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('wide', 30999995, 'null_to_empty');
INSERT INTO gt VALUES ('wide', 82999995, 'null_to_empty');
INSERT INTO gt VALUES ('wide', 19000000, 'trailing_space');
INSERT INTO gt VALUES ('wide', 73000000, 'trailing_space');
INSERT INTO gt VALUES ('wide', 29000000, 'float_ulp');
INSERT INTO gt VALUES ('wide', 47000000, 'float_ulp');
INSERT INTO gt VALUES ('wide', 55000000, 'deleted');
INSERT INTO gt VALUES ('wide', 100000001, 'inserted');
INSERT INTO gt VALUES ('toast', 9000000, 'toast_one_char');
INSERT INTO gt VALUES ('toast', 37000000, 'toast_one_char');
INSERT INTO gt VALUES ('toast', 79000000, 'toast_one_char');
INSERT INTO gt VALUES ('toast', 21000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('toast', 58000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('toast', 93000000, 'numeric_last_digit');
INSERT INTO gt VALUES ('toast', 33000000, 'deleted');
INSERT INTO gt VALUES ('toast', 71000000, 'deleted');
INSERT INTO gt VALUES ('toast', 100000001, 'inserted');
INSERT INTO gt VALUES ('toast', 100000002, 'inserted');
UPDATE narrow x SET n2 = n2 + 0.00000001 FROM gt WHERE gt.tbl='narrow' AND gt.cat='numeric_last_digit' AND gt.id = x.id;
UPDATE narrow x SET n1 = n1 + 0.01 FROM gt WHERE gt.tbl='narrow' AND gt.cat='numeric_cents' AND gt.id = x.id;
UPDATE wide x SET u3 = u3 + 0.000000000001 FROM gt WHERE gt.tbl='wide' AND gt.cat='numeric_last_digit' AND gt.id = x.id;
UPDATE wide x SET t1 = '' FROM gt WHERE gt.tbl='wide' AND gt.cat='null_to_empty' AND gt.id = x.id;
UPDATE wide x SET t2 = t2 || ' ' FROM gt WHERE gt.tbl='wide' AND gt.cat='trailing_space' AND gt.id = x.id;
UPDATE wide x SET f1 = f1 * (1 + 2.220446049250313e-16) FROM gt WHERE gt.tbl='wide' AND gt.cat='float_ulp' AND gt.id = x.id;
UPDATE toast x SET payload = overlay(payload placing 'X' from 1000 for 1) FROM gt WHERE gt.tbl='toast' AND gt.cat='toast_one_char' AND gt.id = x.id;
UPDATE toast x SET p1 = p1 + 0.00000001 FROM gt WHERE gt.tbl='toast' AND gt.cat='numeric_last_digit' AND gt.id = x.id;
DELETE FROM narrow x USING gt WHERE gt.tbl='narrow' AND gt.cat='deleted' AND gt.id = x.id;
INSERT INTO narrow SELECT g,
  ((hashint8extended(g, 1) & 9223372036854775807) % 10000000000)::numeric / 100,
  (hashint8extended(g, 2) % 1000000000000000000)::numeric / 100000000,
  round(hashint8extended(g, 3)::numeric / 7, 12),
  hashint8(g),
  timestamptz '2020-01-01 00:00:00+00' + ((hashint8extended(g, 4) & 9223372036854775807) % 157680000) * interval '1 second'
FROM gt, LATERAL (SELECT gt.id AS g) s WHERE gt.tbl='narrow' AND gt.cat='inserted';
DELETE FROM wide x USING gt WHERE gt.tbl='wide' AND gt.cat='deleted' AND gt.id = x.id;
INSERT INTO wide SELECT g,
  ((hashint8extended(g, 10) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 11) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 12) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 13) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 14) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 15) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 16) & 9223372036854775807) % 10000000000)::numeric / 100,
  ((hashint8extended(g, 17) & 9223372036854775807) % 10000000000)::numeric / 100,
  (hashint8extended(g, 20) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 21) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 22) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 23) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 24) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 25) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 26) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 27) % 1000000000000000000)::numeric / 100000000,
  round(hashint8extended(g, 30)::numeric / 7, 12),
  round(hashint8extended(g, 31)::numeric / 7, 12),
  round(hashint8extended(g, 32)::numeric / 7, 12),
  round(hashint8extended(g, 33)::numeric / 7, 12),
  round(hashint8extended(g, 34)::numeric / 7, 12),
  round(hashint8extended(g, 35)::numeric / 7, 12),
  round(hashint8extended(g, 36)::numeric / 7, 12),
  round(hashint8extended(g, 37)::numeric / 7, 12),
  substr(md5(g::text || '-t0'), 1, 8 + ((hashint8extended(g, 40) & 9223372036854775807) % 16)::int),
  CASE WHEN g % 13 = 0 THEN NULL ELSE substr(md5(g::text || '-t1'), 1, 8 + ((hashint8extended(g, 41) & 9223372036854775807) % 16)::int) END,
  substr(md5(g::text || '-t2'), 1, 8 + ((hashint8extended(g, 42) & 9223372036854775807) % 16)::int),
  substr(md5(g::text || '-t3'), 1, 8 + ((hashint8extended(g, 43) & 9223372036854775807) % 16)::int),
  substr(md5(g::text || '-t4'), 1, 8 + ((hashint8extended(g, 44) & 9223372036854775807) % 16)::int),
  substr(md5(g::text || '-t5'), 1, 8 + ((hashint8extended(g, 45) & 9223372036854775807) % 16)::int),
  substr(md5(g::text || '-t6'), 1, 8 + ((hashint8extended(g, 46) & 9223372036854775807) % 16)::int),
  substr(md5(g::text || '-t7'), 1, 8 + ((hashint8extended(g, 47) & 9223372036854775807) % 16)::int),
  hashint8extended(g, 50),
  hashint8extended(g, 51),
  hashint8extended(g, 52),
  hashint8extended(g, 53),
  timestamptz '2020-01-01 00:00:00+00' + ((hashint8extended(g, 60) & 9223372036854775807) % 157680000) * interval '1 second',
  timestamptz '2020-01-01 00:00:00+00' + ((hashint8extended(g, 61) & 9223372036854775807) % 157680000) * interval '1 second',
  hashint8extended(g, 70)::float8 / 7.0,
  hashint8extended(g, 71)::float8 / 7.0
FROM gt, LATERAL (SELECT gt.id AS g) s WHERE gt.tbl='wide' AND gt.cat='inserted';
DELETE FROM toast x USING gt WHERE gt.tbl='toast' AND gt.cat='deleted' AND gt.id = x.id;
INSERT INTO toast SELECT g,
  (hashint8extended(g, 80) % 1000000000000000000)::numeric / 100000000,
  (hashint8extended(g, 81) % 1000000000000000000)::numeric / 100000000,
  round(hashint8extended(g, 82)::numeric / 7, 12),
  round(hashint8extended(g, 83)::numeric / 7, 12),
  repeat(md5(g::text || '-p'), 64 + (g % 65)::int)
FROM gt, LATERAL (SELECT gt.id AS g) s WHERE gt.tbl='toast' AND gt.cat='inserted';
SELECT tbl, cat, count(*) FROM gt GROUP BY 1,2 ORDER BY 1,2;
DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM gt WHERE tbl IN ('narrow','wide','toast');
  IF n <> 30 THEN RAISE EXCEPTION 'gt has % rows, expected 30', n; END IF;
  SELECT count(*) INTO n FROM wide x JOIN gt ON gt.tbl='wide' AND gt.id=x.id AND gt.cat='float_ulp'
   WHERE x.f1 = hashint8extended(x.id, 71)::float8 / 7.0;
  IF n > 0 THEN RAISE EXCEPTION 'float_ulp: % rows unchanged', n; END IF;
  SELECT count(*) INTO n FROM wide x JOIN gt ON gt.tbl='wide' AND gt.id=x.id AND gt.cat='null_to_empty'
   WHERE x.t1 IS DISTINCT FROM '';
  IF n > 0 THEN RAISE EXCEPTION 'null_to_empty: % rows wrong', n; END IF;
  SELECT count(*) INTO n FROM toast x JOIN gt ON gt.tbl='toast' AND gt.id=x.id AND gt.cat='toast_one_char'
   WHERE position('X' in x.payload) <> 1000;
  IF n > 0 THEN RAISE EXCEPTION 'toast_one_char: % rows wrong', n; END IF;
END $$;
COMMIT;
