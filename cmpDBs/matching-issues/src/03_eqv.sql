-- Equal by the operator, different text (and the opposite): E1 .. E18.

-- E1: interval.
CREATE TABLE eqv.e01_interval (id int PRIMARY KEY, v interval);
INSERT INTO eqv.e01_interval VALUES (0, '1 hour');
\if :n1
INSERT INTO eqv.e01_interval VALUES (1, '1 day'), (2, '1 mon');
\else
INSERT INTO eqv.e01_interval VALUES (1, '24 hours'), (2, '30 days');
\endif
CALL ref_meta.reg('E1', 'eqv.e01_interval', 'rows 1, 2 changed by text (1 day / 24:00:00, 1 mon / 30 days); both pairs are equal by =');

-- E2: timetz, the same instant in another zone.
CREATE TABLE eqv.e02_timetz (id int PRIMARY KEY, v timetz);
INSERT INTO eqv.e02_timetz VALUES (0, '12:00:00+00');
\if :n1
INSERT INTO eqv.e02_timetz VALUES (1, '10:00:00+02');
\else
INSERT INTO eqv.e02_timetz VALUES (1, '08:00:00+00');
\endif
CALL ref_meta.reg('E2', 'eqv.e02_timetz', 'row 1 changed: the same instant, but not equal by = either');

-- E3: citext as a value and as a key.
CREATE TABLE eqv.e03_citext (id int PRIMARY KEY, v citext);
CREATE TABLE eqv.e03_citext_key (id citext PRIMARY KEY, v text);
INSERT INTO eqv.e03_citext VALUES (0, 'same');
INSERT INTO eqv.e03_citext_key VALUES ('same', 'x');
\if :n1
INSERT INTO eqv.e03_citext VALUES (1, 'Alice');
INSERT INTO eqv.e03_citext_key VALUES ('Alice', 'x');
\else
INSERT INTO eqv.e03_citext VALUES (1, 'alice');
INSERT INTO eqv.e03_citext_key VALUES ('alice', 'x');
\endif
CALL ref_meta.reg('E3', 'eqv.e03_citext', 'row 1 changed by text (Alice / alice), equal by =');
CALL ref_meta.reg('E3', 'eqv.e03_citext_key', 'key Alice only on n1, key alice only on n2; repair INSERT hits the unique index');
CALL ref_meta.reg('E7', 'eqv.e03_citext_key', 'citext key: equal values can have different text');
CALL ref_meta.reg('K10', 'eqv.e03_citext_key', 'key of an extension type');

-- E4: non-deterministic ICU collations; NFC and NFD forms.
CREATE COLLATION eqv.ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false);
CREATE COLLATION eqv.nd (provider = icu, locale = 'und', deterministic = false);
CREATE TABLE eqv.e04_nondet (id int PRIMARY KEY, v text COLLATE eqv.ci_ai);
CREATE TABLE eqv.e04_nondet_key (id text COLLATE eqv.ci_ai PRIMARY KEY, v text);
CREATE TABLE eqv.e04_nfc_nfd (id int PRIMARY KEY, v text, w text COLLATE eqv.nd);
CREATE TABLE eqv.e04_nfc_nfd_key (id text COLLATE eqv.nd PRIMARY KEY, v text);
INSERT INTO eqv.e04_nondet VALUES (0, 'same');
INSERT INTO eqv.e04_nondet_key VALUES ('same', 'x');
INSERT INTO eqv.e04_nfc_nfd VALUES (0, 'same', 'same');
INSERT INTO eqv.e04_nfc_nfd_key VALUES ('same', 'x');
\if :n1
INSERT INTO eqv.e04_nondet VALUES (1, U&'R\00E9sum\00E9');
INSERT INTO eqv.e04_nondet_key VALUES ('Alice', 'x');
INSERT INTO eqv.e04_nfc_nfd VALUES (1, U&'caf\00E9', U&'caf\00E9');
INSERT INTO eqv.e04_nfc_nfd_key VALUES (U&'caf\00E9', 'x');
\else
INSERT INTO eqv.e04_nondet VALUES (1, 'resume');
INSERT INTO eqv.e04_nondet_key VALUES ('ALICE', 'x');
INSERT INTO eqv.e04_nfc_nfd VALUES (1, U&'cafe\0301', U&'cafe\0301');
INSERT INTO eqv.e04_nfc_nfd_key VALUES (U&'cafe\0301', 'x');
\endif
CALL ref_meta.reg('E4', 'eqv.e04_nondet', 'row 1 changed by text; equal by = under the collation');
CALL ref_meta.reg('E4', 'eqv.e04_nondet_key', 'key Alice only on n1, ALICE only on n2; equal by =');
CALL ref_meta.reg('E4', 'eqv.e04_nfc_nfd', 'row 1 changed: NFC / NFD; v differs by = too, w is equal by =');
CALL ref_meta.reg('E4', 'eqv.e04_nfc_nfd_key', 'NFC key only on n1, NFD key only on n2; equal by =');
CALL ref_meta.reg('E7', 'eqv.e04_nondet_key', 'text key with a non-deterministic collation: equal values can have different text');

-- E5: jsonb numbers.
CREATE TABLE eqv.e05_jsonb (id int PRIMARY KEY, v jsonb);
INSERT INTO eqv.e05_jsonb VALUES (0, '{"a": 1}');
\if :n1
INSERT INTO eqv.e05_jsonb VALUES (1, '{"a": 1.0}'), (2, '{"b": 1, "a": 2}');
\else
INSERT INTO eqv.e05_jsonb VALUES (1, '{"a": 1.00}'), (2, '{"a": 2, "b": 1}');
\endif
CALL ref_meta.reg('E5', 'eqv.e05_jsonb', 'row 1 changed by text (1.0 / 1.00), equal by =; row 2 is equal (jsonb orders the keys)');

-- E8: text key under the default (not C) collation, mixed case.
CREATE TABLE eqv.e08_text_key_collation (id text PRIMARY KEY, v text);
INSERT INTO eqv.e08_text_key_collation
	SELECT CASE WHEN i % 2 = 0 THEN chr(65 + i % 26) ELSE chr(97 + i % 26) END || '-' || lpad(i::text, 5, '0'), 'v' || i
	FROM generate_series(1, 5000) i;
INSERT INTO eqv.e08_text_key_collation VALUES ('a-a', 'x'), ('a+a', 'x'), ('aa', 'x'), ('B', 'x'), ('b', 'x'), ('_x', 'x'), ('10', 'x'), ('9', 'x');
\if :n2
UPDATE eqv.e08_text_key_collation SET v = 'changed'
	WHERE id IN ('a-a', 'B', '9')
	   OR id IN (SELECT CASE WHEN i % 2 = 0 THEN chr(65 + i % 26) ELSE chr(97 + i % 26) END || '-' || lpad(i::text, 5, '0') FROM unnest(ARRAY[1, 26, 27, 2611, 2612, 5000]) i);
\endif
CALL ref_meta.reg('E8', 'eqv.e08_text_key_collation', '9 changed rows; all must be found, also by a tool that sorts or splits the keys outside the server');

-- E9: bpchar without a length.
CREATE TABLE eqv.e09_bpchar (id int PRIMARY KEY, v bpchar);
CREATE TABLE eqv.e09_bpchar_key (id bpchar PRIMARY KEY, v text);
INSERT INTO eqv.e09_bpchar VALUES (0, 'same');
INSERT INTO eqv.e09_bpchar_key VALUES ('same', 'x');
\if :n1
INSERT INTO eqv.e09_bpchar VALUES (1, 'a  ');
INSERT INTO eqv.e09_bpchar_key VALUES ('a  ', 'x');
\else
INSERT INTO eqv.e09_bpchar VALUES (1, 'a');
INSERT INTO eqv.e09_bpchar_key VALUES ('a', 'x');
\endif
CALL ref_meta.reg('E9', 'eqv.e09_bpchar', 'row 1 changed by text ("a  " / "a"), equal by =');
CALL ref_meta.reg('E9', 'eqv.e09_bpchar_key', 'key "a  " only on n1, key "a" only on n2; equal by =');

-- E10: ranges with numeric bounds.
CREATE TABLE eqv.e10_range (id int PRIMARY KEY, r numrange, mr nummultirange);
INSERT INTO eqv.e10_range VALUES (0, '[1,2]', '{[1,2]}');
\if :n1
INSERT INTO eqv.e10_range VALUES (1, '[1.0,2.0]', '{[1.0,2.0],[5,6]}');
\else
INSERT INTO eqv.e10_range VALUES (1, '[1,2]', '{[1,2],[5,6]}');
\endif
CALL ref_meta.reg('E10', 'eqv.e10_range', 'row 1 changed by text, equal by =');

-- E11: array lower bounds.
CREATE TABLE eqv.e11_array_bounds (id int PRIMARY KEY, a int[]);
INSERT INTO eqv.e11_array_bounds VALUES (0, '[0:2]={1,2,3}');
\if :n1
INSERT INTO eqv.e11_array_bounds VALUES (1, '[0:2]={1,2,3}'), (2, '[5:6]={7,8}');
\else
INSERT INTO eqv.e11_array_bounds VALUES (1, '{1,2,3}');
\endif
CALL ref_meta.reg('E11', 'eqv.e11_array_bounds', 'row 1 changed (lower bound 0 / 1), row 2 only on n1; after repair the text on n2 keeps the [0:2]= and [5:6]= prefix; row 0 equal');

-- E12: empty array, NULL array, NULL elements.
CREATE TABLE eqv.e12_array_nulls (id int PRIMARY KEY, a text[]);
INSERT INTO eqv.e12_array_nulls VALUES (0, '{}'), (10, NULL), (11, '{NULL}'), (12, '{NULL,"NULL",""}');
\if :n1
INSERT INTO eqv.e12_array_nulls VALUES (1, '{}'), (2, NULL), (3, '{NULL}'), (4, '{NULL,"NULL",""}');
\else
INSERT INTO eqv.e12_array_nulls VALUES (1, NULL), (2, '{}'), (3, '{}'), (4, '{NULL,NULL,NULL}');
\endif
CALL ref_meta.reg('E12', 'eqv.e12_array_nulls', 'rows 1-4 changed; rows 0, 10, 11, 12 equal; after repair every text is kept');

-- E13: a composite of NULLs against NULL.
CREATE TYPE eqv.e13_pair AS (a int, b text);
CREATE TABLE eqv.e13_row_nulls (id int PRIMARY KEY, c eqv.e13_pair);
INSERT INTO eqv.e13_row_nulls VALUES (0, ROW(NULL, NULL)), (10, NULL);
\if :n1
INSERT INTO eqv.e13_row_nulls VALUES (1, ROW(NULL, NULL)), (2, ROW(1, NULL));
\else
INSERT INTO eqv.e13_row_nulls VALUES (1, NULL), (2, ROW(1, ''));
\endif
CALL ref_meta.reg('E13', 'eqv.e13_row_nulls', 'row 1 changed: (,) / NULL, although both are "IS NULL"; row 2 changed: (1,) / (1,"")');

-- E14: json keeps the text as typed.
CREATE TABLE eqv.e14_json (id int PRIMARY KEY, j json);
INSERT INTO eqv.e14_json VALUES (0, '{"a":1,"a":2}');
\if :n1
INSERT INTO eqv.e14_json VALUES (1, '{"a":1,"a":2}'), (2, '{"a": 1}'), (3, '{"b":1,"a":2}');
\else
INSERT INTO eqv.e14_json VALUES (1, '{"a":2}'), (2, '{"a":1}'), (3, '{"a":2,"b":1}');
\endif
CALL ref_meta.reg('E14', 'eqv.e14_json', 'rows 1-3 changed by text (duplicate key, a space, key order); json has no equality operator');

-- E15: time edge values.
CREATE TABLE eqv.e15_time (id int PRIMARY KEY, t time);
\if :n1
INSERT INTO eqv.e15_time VALUES (1, '23:59:60'), (2, '24:00:00');
\else
INSERT INTO eqv.e15_time VALUES (1, '24:00:00'), (2, '00:00:00');
\endif
CALL ref_meta.reg('E15', 'eqv.e15_time', 'row 1 equal (23:59:60 is stored as 24:00:00); row 2 changed (24:00:00 / 00:00:00)');

-- E16: interval as a key.
CREATE TABLE eqv.e16_interval_key (id interval PRIMARY KEY, v text);
INSERT INTO eqv.e16_interval_key VALUES ('1 hour', 'same');
\if :n1
INSERT INTO eqv.e16_interval_key VALUES ('1 day', 'x'), ('infinity', 'only n1');
\else
INSERT INTO eqv.e16_interval_key VALUES ('24 hours', 'x');
\endif
CALL ref_meta.reg('E16', 'eqv.e16_interval_key', 'key "1 day" only on n1, key "24:00:00" only on n2 (equal by =); key infinity only on n1');

-- E17: invisible characters.
CREATE TABLE eqv.e17_invisible (id int PRIMARY KEY, what text, v text);
\if :n1
INSERT INTO eqv.e17_invisible VALUES
	(1, 'zero-width space', U&'abc\200B'),
	(2, 'no-break space', U&'a\00A0b'),
	(3, 'byte order mark', U&'\FEFFabc'),
	(4, 'trailing CR', E'line\r'),
	(5, 'Cyrillic a', U&'p\0430y'),
	(6, 'trailing space', 'abc ');
\else
INSERT INTO eqv.e17_invisible VALUES
	(1, 'zero-width space', 'abc'),
	(2, 'no-break space', 'a b'),
	(3, 'byte order mark', 'abc'),
	(4, 'trailing CR', 'line'),
	(5, 'Cyrillic a', 'pay'),
	(6, 'trailing space', 'abc');
\endif
CALL ref_meta.reg('E17', 'eqv.e17_invisible', '6 changed rows; the report should let a person see the difference');

-- E18: xml keeps the text as typed.
CREATE TABLE eqv.e18_xml (id int PRIMARY KEY, x xml);
INSERT INTO eqv.e18_xml VALUES (0, '<a/>');
\if :n1
INSERT INTO eqv.e18_xml VALUES (1, '<?xml version="1.0"?><a/>'), (2, '<a> </a>'), (3, '<a b="1" c="2"/>');
\else
INSERT INTO eqv.e18_xml VALUES (1, '<a/>'), (2, '<a></a>'), (3, '<a c="2" b="1"/>');
\endif
CALL ref_meta.reg('E18', 'eqv.e18_xml', 'rows 1-3 changed by text; xml has no equality operator');
