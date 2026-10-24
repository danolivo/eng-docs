-- Spot check: md5 of the text of 18 sample rows against the values computed
-- when the dataset was built (PostgreSQL 18.6). Works on both the reference
-- and the test instance: none of these ids is among the 30 differences.
-- Every line must say OK.
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, YMD';
SET extra_float_digits = 1;
WITH expected(tbl, id, md5) AS (VALUES
  ('narrow', 1, 'e2d5178eb9b45ec1b6ce6de7c692a72e'),
  ('narrow', 2, '0cb55a2fb49893367ae82ebfe2745336'),
  ('narrow', 12345678, '780e5fd227fcd84299134c74bbcb1d9f'),
  ('narrow', 50000000, 'bd038a02aacdf675f943fb96956751df'),
  ('narrow', 99999999, '4119a6620e233e60eb4c93b8ad1e87c5'),
  ('narrow', 100000000, 'b3bcf18fd61727c92054fb24b0b9a116'),
  ('toast', 1, 'f19caee3cdcc51a265ac9ee99cdcff1c'),
  ('toast', 2, '12698125f8a4ab84fcf0d5435c1dc4f7'),
  ('toast', 12345678, '25cbbdfe525fc8a054438f8eb8d5598c'),
  ('toast', 50000000, '98d1a0a773f3787981136b053806c72a'),
  ('toast', 99999999, 'f7e4d86db560129b4a165e4f9f0a0fe6'),
  ('toast', 100000000, 'a0031a2989c6aa8bf84ae67b7b7e2465'),
  ('wide', 1, '37f9ad8ea441727a19c21807d3262f90'),
  ('wide', 2, '6aefc12a3bdcbefbf793e9ea156212f7'),
  ('wide', 12345678, '0d7cf4901f5f6ac62ab342c5c21d2ebe'),
  ('wide', 50000000, '4de6dd31046164a76451dff43a0daa81'),
  ('wide', 99999999, 'a49fc093f5068961ec17895577b24047'),
  ('wide', 100000000, '2fc5623cdc7388852cb686f08380261d')
), actual AS (
  SELECT 'narrow' AS tbl, id, md5(t::text) FROM narrow t WHERE id IN (SELECT id FROM expected WHERE tbl = 'narrow')
  UNION ALL
  SELECT 'wide', id, md5(t::text) FROM wide t WHERE id IN (SELECT id FROM expected WHERE tbl = 'wide')
  UNION ALL
  SELECT 'toast', id, md5(t::text) FROM toast t WHERE id IN (SELECT id FROM expected WHERE tbl = 'toast')
)
SELECT e.tbl, e.id, CASE WHEN a.md5 = e.md5 THEN 'OK' WHEN a.md5 IS NULL THEN 'MISSING' ELSE 'DIFFERS' END AS result
  FROM expected e LEFT JOIN actual a USING (tbl, id)
 ORDER BY e.tbl, e.id;
