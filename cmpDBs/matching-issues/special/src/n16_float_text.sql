-- Case N16: float text on a server older than PostgreSQL 12.
-- Stand: one server of version 11 or older and one of version 12 or newer.
-- Run:   the same data on both.
-- Expect: the stored values are bit-equal. With extra_float_digits = 3 the old
--         server prints 17 digits (0.10000000000000001), the new one prints
--         the shortest exact form (0.1): the rows differ by text. Only
--         relevant if such old servers are supported.
DROP TABLE IF EXISTS sp.n16_float_text;
CREATE TABLE sp.n16_float_text (id int PRIMARY KEY, f float8, g float4);
INSERT INTO sp.n16_float_text VALUES
	(1, 0.1, 0.1), (2, 0.3, 0.3), (3, 1.1, 1.1), (4, 1e-7, 1e-7), (5, 123456.789, 123456.789),
	(6, 0.5, 0.5), (7, 1, 1), (8, 1e22, 1e22), (9, 2.2250738585072014e-308, 1.17549435e-38), (10, 'NaN', '-Infinity');
COMMENT ON TABLE sp.n16_float_text IS 'N16: rows 1-5, 8, 9 differ by text between a server before 12 and a newer one; rows 6, 7, 10 are equal';
