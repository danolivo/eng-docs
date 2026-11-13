-- Types and table definitions: T1 .. T19.

-- T1: the type modifier of a numeric key differs.
\if :n1
CREATE TABLE typ.t01_key_typmod_numeric (id numeric(7,2) PRIMARY KEY, v text);
INSERT INTO typ.t01_key_typmod_numeric VALUES (1.50, 'same'), (999.99, 'n1'), (12345.67, 'only n1, does not fit numeric(5,2)');
\else
CREATE TABLE typ.t01_key_typmod_numeric (id numeric(5,2) PRIMARY KEY, v text);
INSERT INTO typ.t01_key_typmod_numeric VALUES (1.50, 'same'), (999.99, 'n2');
\endif
CALL ref_meta.reg('T1', 'typ.t01_key_typmod_numeric', 'key 999.99 changed, key 12345.67 only on n1; no "numeric field overflow" in the diff; repair INSERT of 12345.67 into n2 fails and is recorded');

-- T2: the type modifier of a string key differs.
\if :n1
CREATE TABLE typ.t02_key_typmod_varchar (id varchar(10) PRIMARY KEY, v text);
INSERT INTO typ.t02_key_typmod_varchar VALUES ('xy', 'same'), ('abc', 'n1'), ('abcdef', 'only n1, a cut to 3 chars gives abc');
\else
CREATE TABLE typ.t02_key_typmod_varchar (id varchar(3) PRIMARY KEY, v text);
INSERT INTO typ.t02_key_typmod_varchar VALUES ('xy', 'same'), ('abc', 'n2');
\endif
CALL ref_meta.reg('T2', 'typ.t02_key_typmod_varchar', 'key abc changed, key abcdef only on n1; abcdef must not be taken for abc');

-- T3: a value that does not fit the type modifier of the target.
\if :n1
CREATE TABLE typ.t03_value_typmod (id int PRIMARY KEY, s varchar(20), n numeric(12,3));
INSERT INTO typ.t03_value_typmod VALUES (0, 'ok', 1.000), (1, 'a long string here', 123456789.125), (2, 'ok', 1.005);
\else
CREATE TABLE typ.t03_value_typmod (id int PRIMARY KEY, s varchar(5), n numeric(10,2));
INSERT INTO typ.t03_value_typmod VALUES (0, 'ok', 1.00), (1, 'a lon', 1.00), (2, 'ok', 1.00);
\endif
CALL ref_meta.reg('T3', 'typ.t03_value_typmod', 'all 3 rows differ by text (scale 3 / 2); repair n1 -> n2: row 1 fails (too long, overflow), row 2 is rounded to 1.01 without an error and differs again');
CALL ref_meta.reg('T5', 'typ.t03_value_typmod', 'type modifiers of non-key columns differ: is it said at the start?');

-- T4: char(n) and bit(n) keys.
CREATE TABLE typ.t04_key_char (id char(5) PRIMARY KEY, v text);
CREATE TABLE typ.t04_key_bit (id bit(8) PRIMARY KEY, v text);
INSERT INTO typ.t04_key_char VALUES ('a', 'same'), ('ab', 'same');
INSERT INTO typ.t04_key_bit VALUES (B'00000001', 'same'), (B'10000000', 'same');
\if :n1
INSERT INTO typ.t04_key_char VALUES ('abc', 'n1'), ('abcde', 'only n1');
INSERT INTO typ.t04_key_bit VALUES (B'10000001', 'n1'), (B'11111111', 'only n1');
\else
INSERT INTO typ.t04_key_char VALUES ('abc', 'n2');
INSERT INTO typ.t04_key_bit VALUES (B'10000001', 'n2');
\endif
CALL ref_meta.reg('T4', 'typ.t04_key_char', 'key abc changed, abcde only on n1; keys a and ab untouched (a cast to char(1) would merge a, ab, abc)');
CALL ref_meta.reg('T4', 'typ.t04_key_bit', 'key 10000001 changed, 11111111 only on n1');
CALL ref_meta.reg('K18', 'typ.t04_key_bit', 'bit(n) key');

-- T5: type modifiers of a non-key column differ, the values are the same.
\if :n1
CREATE TABLE typ.t05_nonkey_typmod (id int PRIMARY KEY, amount numeric(12,2), code varchar(20));
\else
CREATE TABLE typ.t05_nonkey_typmod (id int PRIMARY KEY, amount numeric(10,2), code varchar(10));
\endif
INSERT INTO typ.t05_nonkey_typmod VALUES (1, 10.50, 'A'), (2, 99999999.99, 'B');
CALL ref_meta.reg('T5', 'typ.t05_nonkey_typmod', 'data match; the definitions differ (numeric(12,2) / numeric(10,2), varchar(20) / varchar(10))');

-- T6: the type of the key differs.
\if :n1
CREATE TABLE typ.t06_key_int4_int8 (id int PRIMARY KEY, v text);
INSERT INTO typ.t06_key_int4_int8 VALUES (1, 'same'), (2, 'n1');
\else
CREATE TABLE typ.t06_key_int4_int8 (id bigint PRIMARY KEY, v text);
INSERT INTO typ.t06_key_int4_int8 VALUES (1, 'same'), (2, 'n2'), (3000000000, 'only n2, does not fit int4');
\endif
CALL ref_meta.reg('T6', 'typ.t06_key_int4_int8', 'key types differ (int4 / int8): refused, or key 2 changed and key 3000000000 only on n2');

-- T7: the type of a non-key column differs, the values are "the same".
\if :n1
CREATE TABLE typ.t07_int8_int4 (id int PRIMARY KEY, v bigint);
CREATE TABLE typ.t07_text_varchar (id int PRIMARY KEY, v text);
CREATE TABLE typ.t07_tstz_ts (id int PRIMARY KEY, v timestamptz);
CREATE TABLE typ.t07_numeric_float8 (id int PRIMARY KEY, v numeric);
CREATE TABLE typ.t07_jsonb_json (id int PRIMARY KEY, v jsonb);
CREATE TABLE typ.t07_bpchar_varchar (id int PRIMARY KEY, v char(5));
CREATE TABLE typ.t07_date_ts (id int PRIMARY KEY, v date);
CREATE TABLE typ.t07_ts3_ts6 (id int PRIMARY KEY, v timestamp(3));
\else
CREATE TABLE typ.t07_int8_int4 (id int PRIMARY KEY, v int);
CREATE TABLE typ.t07_text_varchar (id int PRIMARY KEY, v varchar(64));
CREATE TABLE typ.t07_tstz_ts (id int PRIMARY KEY, v timestamp);
CREATE TABLE typ.t07_numeric_float8 (id int PRIMARY KEY, v float8);
CREATE TABLE typ.t07_jsonb_json (id int PRIMARY KEY, v json);
CREATE TABLE typ.t07_bpchar_varchar (id int PRIMARY KEY, v varchar(10));
CREATE TABLE typ.t07_date_ts (id int PRIMARY KEY, v timestamp);
CREATE TABLE typ.t07_ts3_ts6 (id int PRIMARY KEY, v timestamp(6));
\endif
INSERT INTO typ.t07_int8_int4 VALUES (1, 42);
INSERT INTO typ.t07_text_varchar VALUES (1, 'abc');
INSERT INTO typ.t07_tstz_ts VALUES (1, '2026-06-01 12:00:00+00');
INSERT INTO typ.t07_numeric_float8 VALUES (1, 1.10), (2, 0.1);
INSERT INTO typ.t07_jsonb_json VALUES (1, '{"b":1,"a":2}');
INSERT INTO typ.t07_bpchar_varchar VALUES (1, 'ab');
INSERT INTO typ.t07_date_ts VALUES (1, '2026-06-01');
INSERT INTO typ.t07_ts3_ts6 VALUES (1, '2026-06-01 12:00:00.123');
CALL ref_meta.reg('T7', 'typ.t07_int8_int4', 'types differ (int8 / int4); text 42 on both: match');
CALL ref_meta.reg('T7', 'typ.t07_text_varchar', 'types differ (text / varchar(64)); match');
CALL ref_meta.reg('T7', 'typ.t07_tstz_ts', 'types differ (timestamptz / timestamp); text differs by +00');
CALL ref_meta.reg('T7', 'typ.t07_numeric_float8', 'types differ (numeric / float8); row 1 differs by text (1.10 / 1.1), row 2 is equal by text');
CALL ref_meta.reg('T7', 'typ.t07_jsonb_json', 'types differ (jsonb / json); text differs by key order and spaces');
CALL ref_meta.reg('T7', 'typ.t07_bpchar_varchar', 'types differ (char(5) / varchar(10)); text differs by padding');
-- E6: bpchar padding against varchar.
CALL ref_meta.reg('E6', 'typ.t07_bpchar_varchar', 'bpchar padding against varchar');
CALL ref_meta.reg('T7', 'typ.t07_date_ts', 'types differ (date / timestamp); text differs by 00:00:00');
CALL ref_meta.reg('T7', 'typ.t07_ts3_ts6', 'types differ (timestamp(3) / timestamp(6)); match by text');

-- T8: user types with the same definition; their OIDs differ on each node.
CREATE TYPE typ.t08_color AS ENUM ('red', 'green', 'blue');
CREATE DOMAIN typ.t08_dom AS int CHECK (VALUE > 0);
CREATE TYPE typ.t08_pair AS (a int, b text);
CREATE TABLE typ.t08_user_types (id int PRIMARY KEY, e typ.t08_color, d typ.t08_dom, c typ.t08_pair, ea typ.t08_color[]);
INSERT INTO typ.t08_user_types VALUES (1, 'red', 5, '(1,x)', '{red,blue}'), (2, 'blue', 7, '(2,"y z")', '{}');
CALL ref_meta.reg('T8', 'typ.t08_user_types', 'match: the type OIDs differ, the data does not');

-- T9: attribute numbers differ (a dropped attribute or column on n1).
\if :n1
CREATE TYPE typ.t09_ct AS (a int);
ALTER TYPE typ.t09_ct DROP ATTRIBUTE a, ADD ATTRIBUTE b int;
CREATE TABLE typ.t09_dropped_col (id int PRIMARY KEY, x text, v text);
ALTER TABLE typ.t09_dropped_col DROP COLUMN x;
\else
CREATE TYPE typ.t09_ct AS (b int);
CREATE TABLE typ.t09_dropped_col (id int PRIMARY KEY, v text);
\endif
CREATE TABLE typ.t09_composite_attnum (id int PRIMARY KEY, c typ.t09_ct);
INSERT INTO typ.t09_composite_attnum VALUES (1, '(5)'), (2, '(7)');
INSERT INTO typ.t09_dropped_col VALUES (1, 'a'), (2, 'b');
CALL ref_meta.reg('T9', 'typ.t09_composite_attnum', 'data match; a comparison of the structure reports the attribute number');
CALL ref_meta.reg('T9', 'typ.t09_dropped_col', 'match: a dropped column on n1 must not matter');
-- D6: generated columns, dropped columns, another column order.
CALL ref_meta.reg('D6', 'typ.t09_dropped_col', 'dropped column');

-- T10: an enum label and a domain constraint that exist on one node only.
\if :n1
CREATE TYPE typ.t10_mood AS ENUM ('sad', 'ok', 'happy', 'ecstatic');
CREATE DOMAIN typ.t10_pos AS int;
\else
CREATE TYPE typ.t10_mood AS ENUM ('sad', 'ok', 'happy');
CREATE DOMAIN typ.t10_pos AS int CHECK (VALUE > 0);
\endif
CREATE TABLE typ.t10_enum_extra (id int PRIMARY KEY, e typ.t10_mood);
CREATE TABLE typ.t10_domain_check (id int PRIMARY KEY, d typ.t10_pos);
INSERT INTO typ.t10_enum_extra VALUES (0, 'ok');
INSERT INTO typ.t10_domain_check VALUES (0, 1);
\if :n1
INSERT INTO typ.t10_enum_extra VALUES (1, 'ecstatic'), (2, 'happy');
INSERT INTO typ.t10_domain_check VALUES (1, -5), (2, 5);
\endif
CALL ref_meta.reg('T10', 'typ.t10_enum_extra', 'rows 1, 2 only on n1; repair: row 1 fails on n2 (no such enum label), row 2 is applied');
CALL ref_meta.reg('T10', 'typ.t10_domain_check', 'rows 1, 2 only on n1; repair: row 1 fails on n2 (domain check), row 2 is applied');

-- T11: the same columns in another order.
\if :n1
CREATE TABLE typ.t11_col_order (id int PRIMARY KEY, a text, b text);
\else
CREATE TABLE typ.t11_col_order (b text, a text, id int PRIMARY KEY);
\endif
INSERT INTO typ.t11_col_order (id, a, b) VALUES (1, 'a1', 'b1'), (2, 'a2', 'b2'), (3, 'x', 'x');
CALL ref_meta.reg('T11', 'typ.t11_col_order', 'match: only the column order differs');
CALL ref_meta.reg('D6', 'typ.t11_col_order', 'column order');

-- T12: a column that exists on n1 only.
\if :n1
CREATE TABLE typ.t12_extra_col (id int PRIMARY KEY, a text, c text);
\else
CREATE TABLE typ.t12_extra_col (id int PRIMARY KEY, a text);
\endif
INSERT INTO typ.t12_extra_col (id, a) VALUES (1, 'x'), (2, 'y');
CALL ref_meta.reg('T12', 'typ.t12_extra_col', 'column c exists only on n1 (all NULL): refused with a clear message, or the common columns match');

-- T13: NOT NULL on the target only.
\if :n1
CREATE TABLE typ.t13_not_null (id int PRIMARY KEY, c text);
INSERT INTO typ.t13_not_null VALUES (1, NULL), (2, 'x'), (3, 'only n1');
\else
CREATE TABLE typ.t13_not_null (id int PRIMARY KEY, c text NOT NULL DEFAULT 'dflt');
INSERT INTO typ.t13_not_null VALUES (2, 'x');
\endif
CALL ref_meta.reg('T13', 'typ.t13_not_null', 'rows 1, 3 only on n1; repair: row 1 fails on n2 (23502, NULL into NOT NULL) and is recorded, row 3 is applied');

-- T14: the same enum labels in another sort order.
\if :n1
CREATE TYPE typ.t14_e AS ENUM ('a', 'b', 'c');
\else
CREATE TYPE typ.t14_e AS ENUM ('a', 'c');
ALTER TYPE typ.t14_e ADD VALUE 'b' AFTER 'c';
\endif
CREATE TABLE typ.t14_enum_order (e typ.t14_e, n int, v text, PRIMARY KEY (e, n));
INSERT INTO typ.t14_enum_order
	SELECT (ARRAY['a','b','c'])[1 + i % 3]::typ.t14_e, i, 'v' || i FROM generate_series(1, 3000) i;
\if :n2
UPDATE typ.t14_enum_order SET v = 'changed' WHERE n IN (500, 1500, 2500);
\endif
CALL ref_meta.reg('T14', 'typ.t14_enum_order', '3 changed rows (n = 500, 1500, 2500); the enum sort order differs (a,b,c / a,c,b), so block bounds on e select other rows on each node');

-- T15: a stored generated column with another expression on n2.
\if :n1
CREATE TABLE typ.t15_generated (id int PRIMARY KEY, qty int, price numeric, total numeric GENERATED ALWAYS AS (qty * price) STORED);
INSERT INTO typ.t15_generated (id, qty, price) VALUES (1, 2, 10.00), (2, 3, 5.00), (3, 1, 1.00);
\else
CREATE TABLE typ.t15_generated (id int PRIMARY KEY, qty int, price numeric, total numeric GENERATED ALWAYS AS (qty * price * 2) STORED);
INSERT INTO typ.t15_generated (id, qty, price) VALUES (1, 2, 10.00), (2, 3, 5.00);
\endif
CALL ref_meta.reg('T15', 'typ.t15_generated', 'rows 1, 2 changed in total only; row 3 only on n1; repair: a write to a generated column fails; row 3 can be inserted only without the column total');
CALL ref_meta.reg('D6', 'typ.t15_generated', 'generated column');

-- T16: a virtual generated column (PG 18).
\if :n1
CREATE TABLE typ.t16_virtual (id int PRIMARY KEY, qty int, price numeric, total numeric GENERATED ALWAYS AS (qty * price) VIRTUAL);
INSERT INTO typ.t16_virtual (id, qty, price) VALUES (1, 2, 10.00), (2, 3, 5.00), (3, 1, 1.00);
\else
CREATE TABLE typ.t16_virtual (id int PRIMARY KEY, qty int, price numeric, total numeric GENERATED ALWAYS AS (qty * price * 2) VIRTUAL);
INSERT INTO typ.t16_virtual (id, qty, price) VALUES (1, 2, 10.00), (2, 3, 5.00);
\endif
CALL ref_meta.reg('T16', 'typ.t16_virtual', 'as t15_generated, but nothing is stored: the difference of rows 1, 2 cannot be repaired by data');

-- T17: GENERATED ALWAYS AS IDENTITY key.
CREATE TABLE typ.t17_identity_always (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v text);
\if :n1
INSERT INTO typ.t17_identity_always (v) VALUES ('one'), ('two'), ('three'), ('four');
\else
INSERT INTO typ.t17_identity_always (v) VALUES ('one'), ('two changed on n2');
\endif
CALL ref_meta.reg('T17', 'typ.t17_identity_always', 'row 2 changed, rows 3, 4 only on n1; repair INSERT needs OVERRIDING SYSTEM VALUE');

-- T18: the sequence of the target stays behind after a repair.
CREATE TABLE typ.t18_serial (id serial PRIMARY KEY, v text);
\if :n1
INSERT INTO typ.t18_serial (v) SELECT 'row ' || i FROM generate_series(1, 10) i;
\else
INSERT INTO typ.t18_serial (v) SELECT 'row ' || i FROM generate_series(1, 5) i;
\endif
CALL ref_meta.reg('T18', 'typ.t18_serial', 'rows 6-10 only on n1; after repair of n2 its sequence is still at 5: INSERT INTO typ.t18_serial (v) VALUES (''x'') fails with 23505');
CALL ref_meta.reg('P16', 'typ.t18_serial', 'sequence state differs (10 / 5) and is not compared');

-- T19: the type modifier is a dimension.
\if :n1
CREATE TABLE typ.t19_vector (id int PRIMARY KEY, v vector(3));
CREATE TABLE typ.t19_bit (id int PRIMARY KEY, b bit(8));
INSERT INTO typ.t19_vector VALUES (1, '[1,2,3]'), (2, '[4,5,6]');
INSERT INTO typ.t19_bit VALUES (1, B'10100000'), (2, B'11110000');
\else
CREATE TABLE typ.t19_vector (id int PRIMARY KEY, v vector(4));
CREATE TABLE typ.t19_bit (id int PRIMARY KEY, b bit(16));
INSERT INTO typ.t19_vector VALUES (1, '[1,2,3,0]');
INSERT INTO typ.t19_bit VALUES (1, B'1010000000000000');
\endif
CALL ref_meta.reg('T19', 'typ.t19_vector', 'row 1 changed, row 2 only on n1; repair n1 -> n2 fails for both (expected 4 dimensions, not 3)');
CALL ref_meta.reg('T19', 'typ.t19_bit', 'row 1 changed, row 2 only on n1; repair n1 -> n2 fails (bit string length 8 does not match type bit(16))');
