-- Family B, step 5 (n2 only): 10 differences per table and the ground truth gt.
--
--   psql -v narrow=N -v wide=N -v toast=N -v variants='rk sk id' -f diffs.sql
--
-- N is the row count of the shape; variants lists the variants that were built.
-- Needs the base tables (row type of the inserted rows), so run it before
-- finish.sql drops them. Per shape with N rows (the same ids in every variant):
--   upd_v     id = N*0.10, N*0.35          v = v + 1
--   upd_text  id = N*0.60, N*0.85          one character of pad/payload -> 'X'
--                                          (narrow has no text: v = v + 1 instead)
--   deleted   id = N*0.20, N*0.50, N*0.80
--   inserted  id = N+1, N+2, N+3           new random r, h, v, text
\set ON_ERROR_STOP 1
BEGIN;
DROP TABLE IF EXISTS gt;
CREATE TABLE gt (tbl text, id bigint, cat text, PRIMARY KEY (tbl, id));
CREATE TEMP TABLE shape (s text, n bigint, col text, pos int);
CREATE TEMP TABLE vv AS SELECT unnest(string_to_array(:'variants', ' ')) AS k;
INSERT INTO shape VALUES ('narrow', :narrow, NULL, NULL), ('wide', :wide, 'pad', 100),
                         ('toast', :toast, 'payload', 1500);
CREATE TEMP TABLE ins_narrow AS SELECT r, h, id, v FROM base_narrow LIMIT 0;
CREATE TEMP TABLE ins_wide AS SELECT r, h, id, v, pad FROM base_wide LIMIT 0;
CREATE TEMP TABLE ins_toast AS SELECT r, h, id, v, payload FROM base_toast LIMIT 0;
INSERT INTO ins_narrow SELECT random()::numeric, md5(random()::text), :narrow + g, (random() * 4.6e18)::bigint
  FROM generate_series(1, 3) g;
INSERT INTO ins_wide SELECT random()::numeric, md5(random()::text), :wide + g, (random() * 4.6e18)::bigint,
       substr(repeat(md5(random()::text), 6), 1, 164) FROM generate_series(1, 3) g;
INSERT INTO ins_toast SELECT random()::numeric, md5(random()::text), :toast + g, (random() * 4.6e18)::bigint,
       repeat(md5(random()::text), 91) FROM generate_series(1, 3) g;
DO $$
DECLARE sh record; k text; t text; n bigint; c int;
BEGIN
  FOR sh IN SELECT * FROM shape LOOP
    FOR k IN SELECT vv.k FROM vv LOOP
      t := sh.s || '_' || k;
      INSERT INTO gt SELECT t, round(sh.n * f)::bigint, 'upd_v' FROM unnest(ARRAY[0.10, 0.35]) f;
      INSERT INTO gt SELECT t, round(sh.n * f)::bigint,
                            CASE WHEN sh.col IS NULL THEN 'upd_v' ELSE 'upd_text' END
                       FROM unnest(ARRAY[0.60, 0.85]) f;
      INSERT INTO gt SELECT t, round(sh.n * f)::bigint, 'deleted' FROM unnest(ARRAY[0.20, 0.50, 0.80]) f;
      INSERT INTO gt SELECT t, sh.n + g, 'inserted' FROM generate_series(1, 3) g;
      EXECUTE format('UPDATE %I x SET v = v + 1 FROM gt WHERE gt.tbl = %L AND gt.cat = %L AND x.id = gt.id',
                     t, t, 'upd_v');
      GET DIAGNOSTICS c = ROW_COUNT;
      IF c <> (CASE WHEN sh.col IS NULL THEN 4 ELSE 2 END) THEN RAISE EXCEPTION '%: upd_v hit % rows', t, c; END IF;
      IF sh.col IS NOT NULL THEN
        EXECUTE format('UPDATE %I x SET %I = overlay(%I placing ''X'' from %s for 1) FROM gt
                         WHERE gt.tbl = %L AND gt.cat = %L AND x.id = gt.id',
                       t, sh.col, sh.col, sh.pos, t, 'upd_text');
        GET DIAGNOSTICS c = ROW_COUNT;
        IF c <> 2 THEN RAISE EXCEPTION '%: upd_text hit % rows', t, c; END IF;
      END IF;
      EXECUTE format('DELETE FROM %I x USING gt WHERE gt.tbl = %L AND gt.cat = %L AND x.id = gt.id',
                     t, t, 'deleted');
      GET DIAGNOSTICS c = ROW_COUNT;
      IF c <> 3 THEN RAISE EXCEPTION '%: deleted % rows', t, c; END IF;
      EXECUTE format('INSERT INTO %I SELECT * FROM %I', t, 'ins_' || sh.s);
    END LOOP;
  END LOOP;
  SELECT count(*) INTO n FROM gt;
  IF n <> 30 * (SELECT count(*) FROM vv) THEN RAISE EXCEPTION 'gt has % rows', n; END IF;
END $$;
SELECT tbl, cat, count(*) FROM gt GROUP BY 1, 2 ORDER BY 1, 2;
COMMIT;
