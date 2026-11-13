-- NULL and row encoding: U1 .. U7.

-- U1: NULL against an empty string.
CREATE TABLE nul.u01_null_empty (id int PRIMARY KEY, a text, b text);
INSERT INTO nul.u01_null_empty VALUES (0, 'a', NULL), (10, 'a', '');
\if :n1
INSERT INTO nul.u01_null_empty VALUES (1, 'a', NULL), (2, NULL, 'b'), (3, '', '');
\else
INSERT INTO nul.u01_null_empty VALUES (1, 'a', ''), (2, '', 'b'), (3, NULL, NULL);
\endif
CALL ref_meta.reg('U1', 'nul.u01_null_empty', 'rows 1-3 changed (NULL / empty string); rows 0, 10 equal');

-- U2: a separator inside a value.
CREATE TABLE nul.u02_separator (id int PRIMARY KEY, a text, b text);
\if :n1
INSERT INTO nul.u02_separator VALUES (1, 'a|b', 'c'), (2, 'a,b', 'c'), (3, E'a\tb', 'c'), (4, 'a', NULL), (5, 'ab', '');
\else
INSERT INTO nul.u02_separator VALUES (1, 'a', 'b|c'), (2, 'a', 'b,c'), (3, 'a', E'b\tc'), (4, NULL, 'a'), (5, 'a', 'b');
\endif
CALL ref_meta.reg('U2', 'nul.u02_separator', '5 changed rows; a hash that joins the columns with a separator sees some of them as equal');

-- U3: the text <nil>.
CREATE TABLE nul.u03_nil_literal (id int PRIMARY KEY, note text);
INSERT INTO nul.u03_nil_literal VALUES (0, '<nil>'), (10, ' <nil> ');
\if :n1
INSERT INTO nul.u03_nil_literal VALUES (1, '<nil>'), (2, '<nil>'), (3, '<nil>');
\else
INSERT INTO nul.u03_nil_literal VALUES (1, 'something-else'), (2, NULL);
\endif
CALL ref_meta.reg('U3', 'nul.u03_nil_literal', 'rows 1, 2 changed, row 3 only on n1; after repair from n1 the value on n2 is the text <nil>, not NULL');

-- U4: keys that a YAML repair plan can read as null.
CREATE TABLE nul.u04_null_words (id text PRIMARY KEY, v text);
INSERT INTO nul.u04_null_words VALUES ('same', 'x');
\if :n1
INSERT INTO nul.u04_null_words VALUES ('null', 'n1'), ('NULL', 'n1'), ('~', 'n1'), ('', 'n1'), ('Null', 'only n1'), ('nil', 'only n1');
\else
INSERT INTO nul.u04_null_words VALUES ('null', 'n2'), ('NULL', 'n2'), ('~', 'n2'), ('', 'n2');
\endif
CALL ref_meta.reg('U4', 'nul.u04_null_words', '4 keys changed (null, NULL, ~, empty string), 2 keys only on n1; a plan must be able to name each of them');
CALL ref_meta.reg('K15', 'nul.u04_null_words', 'empty string and the text NULL as keys');

-- U5: NULL inside an array and inside a composite.
CREATE TYPE nul.u05_pair AS (a int, b int);
CREATE TABLE nul.u05_null_inside (id int PRIMARY KEY, arr int[], c nul.u05_pair, ca nul.u05_pair[]);
INSERT INTO nul.u05_null_inside VALUES (0, '{1,NULL,3}', '(1,)', '{"(1,)",NULL}');
\if :n1
INSERT INTO nul.u05_null_inside VALUES (1, '{1,NULL,3}', '(1,)', '{"(1,)",NULL}'), (2, '{NULL}', '(,)', '{NULL}');
\else
INSERT INTO nul.u05_null_inside VALUES (1, '{1,2,3}', '(1,2)', '{"(1,2)","(,)"}');
\endif
CALL ref_meta.reg('U5', 'nul.u05_null_inside', 'row 1 changed, row 2 only on n1; after repair the text on n2 is byte-equal');

-- U6: data for a repair that only fills NULLs.
CREATE TABLE nul.u06_fix_nulls (id int PRIMARY KEY, a text, b text, c numeric);
INSERT INTO nul.u06_fix_nulls VALUES (0, NULL, NULL, NULL);
\if :n1
INSERT INTO nul.u06_fix_nulls VALUES (1, NULL, 'x', NULL), (2, '', NULL, 1.50), (3, 'a', 'b', 1);
\else
INSERT INTO nul.u06_fix_nulls VALUES (1, 'v', 'x', 2.5), (2, NULL, 'y', NULL), (3, 'a', 'b', 1);
\endif
CALL ref_meta.reg('U6', 'nul.u06_fix_nulls', 'rows 1, 2 changed; a repair that only fills NULLs: n1 row 1 gets a = v, c = 2.5; n1 row 2 gets b = y; n2 row 2 gets a = empty string (not NULL), c = 1.50 (scale kept)');

-- U7: composite keys that collide when they are joined into one string.
CREATE TABLE nul.u07_comp_key (k1 text, k2 text, v text, PRIMARY KEY (k1, k2));
INSERT INTO nul.u07_comp_key VALUES ('x', 'y', 'same');
\if :n1
INSERT INTO nul.u07_comp_key VALUES ('a b', 'c', 'n1'), ('a', 'b c', 'only n1'), ('a,b', 'c', 'n1'), ('a', 'b,c', 'only n1'), ('', 'ab', 'n1'), ('a', 'b', 'only n1');
\else
INSERT INTO nul.u07_comp_key VALUES ('a b', 'c', 'n2'), ('a,b', 'c', 'n2'), ('', 'ab', 'n2');
\endif
CALL ref_meta.reg('U7', 'nul.u07_comp_key', '3 keys changed, 3 keys only on n1; no pair of keys may be taken for one key');
CALL ref_meta.reg('K15', 'nul.u07_comp_key', 'composite key with a separator inside');
