-- Numeric and float cases: N1 .. N17.

-- N1: scale of a numeric value that is not a key.
CREATE TABLE num.n01_scale (id int PRIMARY KEY, v numeric);
INSERT INTO num.n01_scale VALUES (0, 1.00);
\if :n1
INSERT INTO num.n01_scale VALUES (1, 3000.00);
\else
INSERT INTO num.n01_scale VALUES (1, 3000.0);
\endif
CALL ref_meta.reg('N1', 'num.n01_scale', '1 changed row (id 1): 3000.00 / 3000.0');

-- N2: scale of a numeric key, simple and composite.
CREATE TABLE num.n02_key_scale (id numeric PRIMARY KEY, v text);
CREATE TABLE num.n02_key_scale_comp (k1 numeric, k2 text, v text, PRIMARY KEY (k1, k2));
INSERT INTO num.n02_key_scale VALUES (3, 'same');
INSERT INTO num.n02_key_scale_comp VALUES (3, 'x', 'same');
\if :n1
INSERT INTO num.n02_key_scale VALUES (1.50, 'a'), (2.000, 'b'), (4.10, 'only n1');
INSERT INTO num.n02_key_scale_comp VALUES (1.50, 'x', 'a'), (2.000, 'x', 'b'), (4.10, 'x', 'only n1');
\else
INSERT INTO num.n02_key_scale VALUES (1.5, 'a'), (2.0, 'b'), (5.00, 'only n2');
INSERT INTO num.n02_key_scale_comp VALUES (1.5, 'x', 'a'), (2.0, 'x', 'b'), (5.00, 'x', 'only n2');
\endif
CALL ref_meta.reg('N2', 'num.n02_key_scale', '3 rows only on n1 (1.50, 2.000, 4.10), 3 rows only on n2 (1.5, 2.0, 5.00); repair: INSERT of 1.50 hits the unique index while 1.5 exists');
CALL ref_meta.reg('N2', 'num.n02_key_scale_comp', 'as n02_key_scale, composite key');

-- N3: repair must keep the scale of the source.
CREATE TABLE num.n03_repair_scale (id int PRIMARY KEY, v numeric, w numeric(10,2));
INSERT INTO num.n03_repair_scale VALUES (0, 1.00, 1.00);
\if :n1
INSERT INTO num.n03_repair_scale VALUES (1, 7.50, 7.50), (2, 4.10, 4.10), (3, 100, 100);
\else
INSERT INTO num.n03_repair_scale VALUES (3, 100.000, 100);
\endif
CALL ref_meta.reg('N3', 'num.n03_repair_scale', '2 rows only on n1, 1 changed row (id 3: 100 / 100.000); after repair from n1 the text of v on n2 is 7.50, 4.10, 100');

-- N4: numeric NaN.
CREATE TABLE num.n04_numeric_nan (id int PRIMARY KEY, v numeric);
INSERT INTO num.n04_numeric_nan VALUES (0, 'NaN');
\if :n1
INSERT INTO num.n04_numeric_nan VALUES (1, 'NaN'), (2, 'NaN');
\else
INSERT INTO num.n04_numeric_nan VALUES (2, 1);
\endif
CALL ref_meta.reg('N4', 'num.n04_numeric_nan', 'row 1 only on n1, row 2 changed (NaN / 1); row 0 equal; repair writes NaN');

-- N5: numeric +-Infinity.
CREATE TABLE num.n05_numeric_inf (id int PRIMARY KEY, v numeric);
INSERT INTO num.n05_numeric_inf VALUES (0, 'Infinity'), (10, '-Infinity');
\if :n1
INSERT INTO num.n05_numeric_inf VALUES (1, 'Infinity'), (2, '-Infinity'), (3, 'Infinity');
\else
INSERT INTO num.n05_numeric_inf VALUES (1, 0), (2, 0);
\endif
CALL ref_meta.reg('N5', 'num.n05_numeric_inf', 'rows 1, 2 changed (Infinity / 0, -Infinity / 0), row 3 only on n1; repair must not write 0');

-- N6: NaN and Infinity as a numeric key.
CREATE TABLE num.n06_key_nan (id numeric PRIMARY KEY, v text);
INSERT INTO num.n06_key_nan VALUES (0, 'same'), (1, 'same');
\if :n1
INSERT INTO num.n06_key_nan VALUES ('NaN', 'n1'), ('Infinity', 'only n1'), ('-Infinity', 'only n1');
\else
INSERT INTO num.n06_key_nan VALUES ('NaN', 'n2');
\endif
CALL ref_meta.reg('N6', 'num.n06_key_nan', 'key NaN changed; keys Infinity and -Infinity only on n1; key 0 must stay untouched by repair');

-- N7: float NaN and Infinity as values and as a key.
CREATE TABLE num.n07_float_special (id int PRIMARY KEY, f float8, g float4);
CREATE TABLE num.n07_float_key (id float8 PRIMARY KEY, v text);
INSERT INTO num.n07_float_special VALUES (0, 'NaN', 'Infinity');
INSERT INTO num.n07_float_key VALUES (1.5, 'same');
\if :n1
INSERT INTO num.n07_float_special VALUES (1, 'NaN', 'Infinity'), (2, 'Infinity', '-Infinity'), (3, '-Infinity', 'NaN');
INSERT INTO num.n07_float_key VALUES ('NaN', 'n1'), ('Infinity', 'only n1'), ('-Infinity', 'only n1');
\else
INSERT INTO num.n07_float_special VALUES (1, 0, 0), (2, 'NaN', 'NaN');
INSERT INTO num.n07_float_key VALUES ('NaN', 'n2');
\endif
CALL ref_meta.reg('N7', 'num.n07_float_special', 'rows 1, 2 changed, row 3 only on n1; the report must hold NaN and Infinity');
CALL ref_meta.reg('N7', 'num.n07_float_key', 'key NaN changed; Infinity and -Infinity only on n1');

-- N8: float8 key -0 on one node and 0 on the other.
CREATE TABLE num.n08_float_zero_key (id float8 PRIMARY KEY, v text);
INSERT INTO num.n08_float_zero_key VALUES (1, 'same');
\if :n1
INSERT INTO num.n08_float_zero_key VALUES ('-0', 'a');
\else
INSERT INTO num.n08_float_zero_key VALUES ('0', 'a');
\endif
CALL ref_meta.reg('N8', 'num.n08_float_zero_key', 'key -0 only on n1, key 0 only on n2 (equal by =); repair INSERT hits the unique index');
-- E7: a key type where equal values can have different text (no bitwise
-- equality): float8, numeric, citext, text with a non-deterministic collation.
CALL ref_meta.reg('E7', 'num.n08_float_zero_key', 'float8 key: equal values can have different text; a warning about the key type is a right answer');
CALL ref_meta.reg('E7', 'num.n02_key_scale', 'numeric key: equal values can have different text; a warning about the key type is a right answer');

-- N9, N17: floats that differ in the last bits.
CREATE TABLE num.n09_float_last_bit (id int PRIMARY KEY, f float8, g float4);
INSERT INTO num.n09_float_last_bit VALUES (0, 0.5, 0.5);
\if :n1
INSERT INTO num.n09_float_last_bit VALUES (1, 0.1::float8 + 0.2::float8, 16777216), (2, 1e15::float8 + 0.125::float8, 0.1);
\else
INSERT INTO num.n09_float_last_bit VALUES (1, 0.3, 16777217), (2, 1e15::float8 + 0.25::float8, 0.1);
\endif
CALL ref_meta.reg('N9', 'num.n09_float_last_bit', 'rows 1, 2 changed in f (0.30000000000000004 / 0.3 and a step of 0.125 at 1e15); g of row 1 is equal (float4 cannot hold 16777217); with extra_float_digits = 0 the difference of row 1 is hidden');
CALL ref_meta.reg('N17', 'num.n09_float_last_bit', 'no tolerance: a one-bit difference is a difference');

-- N10: keys that do not fit into a float64.
CREATE TABLE num.n10_bigint_key (id bigint PRIMARY KEY, v text);
CREATE TABLE num.n10_numeric_key_big (id numeric PRIMARY KEY, v text);
INSERT INTO num.n10_bigint_key VALUES (9007199254740992, 'same');
INSERT INTO num.n10_numeric_key_big VALUES (123456789012345678901234567890, 'same');
\if :n1
INSERT INTO num.n10_bigint_key VALUES (9007199254740993, 'n1'), (9223372036854775807, 'only n1'), (-9223372036854775808, 'n1');
INSERT INTO num.n10_numeric_key_big VALUES (123456789012345678901234567891, 'n1'), (123456789012345678901234567892, 'only n1');
\else
INSERT INTO num.n10_bigint_key VALUES (9007199254740993, 'n2'), (-9223372036854775808, 'n2');
INSERT INTO num.n10_numeric_key_big VALUES (123456789012345678901234567891, 'n2');
\endif
CALL ref_meta.reg('N10', 'num.n10_bigint_key', 'keys ...993 and the bigint minimum changed, bigint maximum only on n1; key ...992 must stay untouched');
-- K18: edge values of a key.
CALL ref_meta.reg('K18', 'num.n10_bigint_key', 'edge values of a bigint key');
CALL ref_meta.reg('N10', 'num.n10_numeric_key_big', 'key ...891 changed, ...892 only on n1; key ...890 untouched');

-- N11: types whose name starts with "numeric" or "date".
CREATE TYPE num.numeric_level AS ENUM ('low', 'high');
CREATE DOMAIN num.numeric_amount AS numeric;
CREATE TABLE num.n11_numeric_named (id int PRIMARY KEY, lvl num.numeric_level, amt num.numeric_amount, arr numeric[], dr daterange);
INSERT INTO num.n11_numeric_named VALUES (0, 'low', 1.00, '{1.00,2}', '[2026-01-01,2026-02-01)');
\if :n1
INSERT INTO num.n11_numeric_named VALUES (1, 'low', 1.50, '{1.50,2.0}', '[2026-01-01,2026-02-01)');
\else
INSERT INTO num.n11_numeric_named VALUES (1, 'high', 1.5, '{1.5,2.0}', '[2026-01-01,2026-03-01)');
\endif
CALL ref_meta.reg('N11', 'num.n11_numeric_named', '1 changed row (id 1), every column differs; the hash query must not fail on these type names');

-- N12: the same text for different values of float4 and float8.
\if :n1
CREATE TABLE num.n12_float4_float8 (id int PRIMARY KEY, v float4);
\else
CREATE TABLE num.n12_float4_float8 (id int PRIMARY KEY, v float8);
\endif
INSERT INTO num.n12_float4_float8 VALUES (1, 0.1), (2, 0.5), (3, 16777216);
CALL ref_meta.reg('N12', 'num.n12_float4_float8', 'column types differ (float4 / float8). Row 1: the texts are equal (0.1), the values are not. Row 3: the values are equal, the texts are not (1.6777216e+07 / 16777216). Row 2 is equal in both ways');

-- N13: NaN on both nodes.
CREATE TABLE num.n13_nan_equal (id int PRIMARY KEY, f float8, g float4, n numeric);
INSERT INTO num.n13_nan_equal VALUES (1, 'NaN', 'NaN', 'NaN'), (2, 'Infinity', '-Infinity', 'Infinity');
CALL ref_meta.reg('N13', 'num.n13_nan_equal', 'match: NaN equals NaN in PostgreSQL');

-- N14: numeric extremes.
CREATE TABLE num.n14_numeric_extreme (id int PRIMARY KEY, a numeric(3,-2), b numeric(2,4), c numeric);
INSERT INTO num.n14_numeric_extreme VALUES
	(0, 12345, 0.0099, repeat('9', 1000)::numeric),
	(1, -99949, -0.0001, '1e-1000'),
	(2, 0, 0, '-0');
\if :n1
INSERT INTO num.n14_numeric_extreme VALUES (3, 100, 0.0050, (repeat('7', 999) || '1')::numeric), (4, 200, 0.0001, '1e-1000');
\else
INSERT INTO num.n14_numeric_extreme VALUES (3, 100, 0.0050, (repeat('7', 999) || '2')::numeric), (4, 200, 0.0001, '2e-1000');
\endif
CALL ref_meta.reg('N14', 'num.n14_numeric_extreme', 'rows 0-2 equal; rows 3, 4 changed in c (last of 1000 digits; 1e-1000 / 2e-1000)');

-- N15: -0 and NaN inside other types.
CREATE TABLE num.n15_inside (id int PRIMARY KEY, p point, fa float8[], nr numrange);
INSERT INTO num.n15_inside VALUES (0, '(1,2)', '{1,2}', '[1,2]');
\if :n1
INSERT INTO num.n15_inside VALUES (1, '(-0,0)', '{-0,NaN}', '[1.0,2.0]');
\else
INSERT INTO num.n15_inside VALUES (1, '(0,0)', '{0,NaN}', '[1,2]');
\endif
CALL ref_meta.reg('N15', 'num.n15_inside', '1 changed row by text: (-0,0) / (0,0), {-0,NaN} / {0,NaN}, [1.0,2.0] / [1,2]; fa and nr are equal by =');
