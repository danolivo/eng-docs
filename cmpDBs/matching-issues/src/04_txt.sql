-- Text output, session settings, special strings: X1 .. X12.

-- X1: types whose ::text cast is not their output function.
CREATE TABLE txt.x01_text_cast (id int PRIMARY KEY, c char(3), b boolean, i inet);
CREATE TABLE txt.x01_bool_key (id boolean PRIMARY KEY, v text);
CREATE TABLE txt.x01_inet_key (id inet PRIMARY KEY, v text);
INSERT INTO txt.x01_text_cast VALUES (0, 'a', true, '1.2.3.4');
INSERT INTO txt.x01_inet_key VALUES ('10.0.0.1', 'same'), ('10.0.0.0/8', 'same');
\if :n1
INSERT INTO txt.x01_text_cast VALUES (1, 'a', true, '1.2.3.4'), (2, 'ab', false, '::1');
INSERT INTO txt.x01_bool_key VALUES (true, 'n1'), (false, 'only n1');
INSERT INTO txt.x01_inet_key VALUES ('192.168.1.1', 'n1'), ('::1', 'only n1');
\else
INSERT INTO txt.x01_text_cast VALUES (1, 'b', false, '1.2.3.5');
INSERT INTO txt.x01_bool_key VALUES (true, 'n2');
INSERT INTO txt.x01_inet_key VALUES ('192.168.1.1', 'n2');
\endif
CALL ref_meta.reg('X1', 'txt.x01_text_cast', 'row 1 changed, row 2 only on n1; the report holds "a  ", t / f and 1.2.3.4 (no /32); after repair the output on n2 is byte-equal');
CALL ref_meta.reg('X1', 'txt.x01_bool_key', 'key t changed, key f only on n1');
CALL ref_meta.reg('R7', 'txt.x01_bool_key', 'a repair plan must name the key t, not true');
CALL ref_meta.reg('X1', 'txt.x01_inet_key', 'key 192.168.1.1 changed, key ::1 only on n1; 10.0.0.1 and 10.0.0.0/8 untouched');

-- X2: values whose text depends on session settings. The data is the same.
-- The block "optional" at the end of node 2 sets other defaults for the
-- database; a tool that does not pin its settings then sees differences.
CREATE TABLE txt.x02_session (id int PRIMARY KEY, ts timestamptz, d date, iv interval, b bytea, f float8, m money);
INSERT INTO txt.x02_session VALUES
	(1, '2026-06-01 12:00:00+00', '2026-02-01', '1 year 2 mons 3 days 04:05:06', '\x00ff10', 0.1::float8 + 0.2::float8, '1234.56'),
	(2, '2026-03-29 01:30:00+00', '2026-12-11', '-1 days +02:00:00', 'abc', 1e-7, '-0.01');
CALL ref_meta.reg('X2', 'txt.x02_session', 'match, whatever defaults the database or the role of a node has (TimeZone, DateStyle, IntervalStyle, bytea_output, extra_float_digits, lc_monetary)');

-- X5: date and time edge values.
CREATE TABLE txt.x05_datetime (id int PRIMARY KEY, tstz timestamptz, ts timestamp, d date, t time, ttz timetz);
INSERT INTO txt.x05_datetime VALUES
	(0, 'infinity', '-infinity', 'infinity', '00:00:00', '00:00:00+00'),
	(10, '2026-03-29 00:59:59.999999+00', '2026-03-29 02:30:00', '2026-03-29', '23:59:59.999999', '23:59:59.999999-12');
\if :n1
INSERT INTO txt.x05_datetime VALUES
	(1, '2026-03-29 01:30:00.000001+00', 'infinity', 'infinity', '12:00:00', '12:00:00+00'),
	(2, '-infinity', '-infinity', '-infinity', '12:00:00.123456', '12:00:00+05:30'),
	(3, '2026-10-25 01:30:00+00', '2026-10-25 02:30:00', '2026-10-25', '02:30:00', '02:30:00+01');
\else
INSERT INTO txt.x05_datetime VALUES
	(1, '2026-03-29 01:30:00.000002+00', '-infinity', '-infinity', '12:00:00', '12:00:00+00'),
	(2, 'infinity', 'infinity', 'infinity', '12:00:00.123457', '12:00:00+05:45');
\endif
CALL ref_meta.reg('X5', 'txt.x05_datetime', 'rows 1, 2 changed (one microsecond, infinity signs), row 3 only on n1; rows 0, 10 equal');

-- X6: money.
CREATE TABLE txt.x06_money (id int PRIMARY KEY, m money);
INSERT INTO txt.x06_money VALUES (0, '1234.56');
\if :n1
INSERT INTO txt.x06_money VALUES (1, '1234.56'), (2, '-99.99');
\else
INSERT INTO txt.x06_money VALUES (1, '1234.57');
\endif
CALL ref_meta.reg('X6', 'txt.x06_money', 'row 1 changed, row 2 only on n1; the value must come back the same under any lc_monetary');

-- X7: strings that look like markers.
CREATE TABLE txt.x07_markers (id int PRIMARY KEY, v text);
INSERT INTO txt.x07_markers VALUES (0, NULL), (100, '\N'), (101, 'NULL'), (102, '');
\if :n1
INSERT INTO txt.x07_markers VALUES
	(1, '\N'), (2, 'NULL'), (3, 'null'), (4, '<nil>'), (5, ''), (6, '   '), (7, 'NaN'),
	(8, 'infinity'), (9, 'true'), (10, '{}'), (11, '()'), (12, NULL), (13, 'nil'), (14, '[]'),
	(15, '~'), (16, '"NULL"');
\else
INSERT INTO txt.x07_markers VALUES
	(1, 'x'), (3, 'x'), (5, 'x'), (7, 'x'), (9, 'x'), (11, 'x'), (12, 'x'), (13, 'x'), (15, 'x');
\endif
CALL ref_meta.reg('X7', 'txt.x07_markers', 'odd ids and 12 changed, even ids only on n1; after repair from n1 every value on n2 is byte-equal, and only id 0 and 12 are NULL');

-- X8: control and quoting characters, as values and as keys.
CREATE TABLE txt.x08_special_chars (id int PRIMARY KEY, v text);
CREATE TABLE txt.x08_special_keys (id text PRIMARY KEY, v text);
INSERT INTO txt.x08_special_chars VALUES (0, E'same\ttab');
INSERT INTO txt.x08_special_keys VALUES (E'same\ttab', 'same');
\if :n1
INSERT INTO txt.x08_special_chars VALUES
	(1, E'tab\there'), (2, E'line1\nline2'), (3, E'cr\rhere'), (4, E'back\\slash'), (5, 'single''quote'),
	(6, 'double"quote'), (7, '%s %d %v'), (8, '$1 $2'), (9, '; DROP TABLE x; --'), (10, '{a,b}'),
	(11, '(a,b)'), (12, 'a|b'), (13, E'\\x41'), (14, '[1,2]'), (15, U&'emoji \+01F600'),
	(16, U&'\043A\0438\0440\0438\043B\043B\0438\0446\0430'), (17, U&'\4E2D\6587'), (18, E'a\u0001b'),
	(19, '<b>html</b> &amp;'), (20, '{"json": "x"}');
INSERT INTO txt.x08_special_keys
	SELECT v, 'key ' || id FROM txt.x08_special_chars WHERE id > 0;
\else
INSERT INTO txt.x08_special_chars SELECT i, 'x' FROM generate_series(1, 19, 2) i;
INSERT INTO txt.x08_special_keys VALUES
	(E'tab\there', 'n2'), (E'cr\rhere', 'n2'), ('single''quote', 'n2'), ('%s %d %v', 'n2'), ('; DROP TABLE x; --', 'n2'),
	('(a,b)', 'n2'), (E'\\x41', 'n2'), (U&'emoji \+01F600', 'n2'), (U&'\4E2D\6587', 'n2'), ('<b>html</b> &amp;', 'n2');
\endif
CALL ref_meta.reg('X8', 'txt.x08_special_chars', 'odd ids changed, even ids only on n1; after repair every value is byte-equal');
CALL ref_meta.reg('X8', 'txt.x08_special_keys', '10 keys changed, 10 keys only on n1; each key finds its own row');
CALL ref_meta.reg('K15', 'txt.x08_special_keys', 'key text with special characters');

-- X12: historical and far dates.
CREATE TABLE txt.x12_old_dates (id int PRIMARY KEY, d date, ts timestamp, tstz timestamptz);
INSERT INTO txt.x12_old_dates VALUES
	(1, '0044-03-15 BC', '0044-03-15 12:00:00 BC', '0044-03-15 12:00:00+00 BC'),
	(2, '4713-01-01 BC', '4713-01-01 00:00:00 BC', '4713-01-01 00:00:00+00 BC'),
	(3, '5874897-12-31', '294276-12-31 23:59:59.999999', '294276-12-31 23:59:59.999999+00'),
	(4, '1883-11-18', '1883-11-18 12:00:00', '1883-11-18 12:00:00+00'),
	(5, '1970-01-01', '1970-01-01 00:00:00', '1970-01-01 00:00:00+00');
\if :n2
UPDATE txt.x12_old_dates SET d = '0044-03-14 BC' WHERE id = 1;
UPDATE txt.x12_old_dates SET tstz = '1883-11-18 12:00:01+00' WHERE id = 4;
\endif
CALL ref_meta.reg('X12', 'txt.x12_old_dates', 'rows 1, 4 changed; rows 2, 3, 5 equal under any TimeZone of the session');
