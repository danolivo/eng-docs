-- Case X4: the nodes run different PostgreSQL major versions.
-- Stand: two servers of different major versions (14 or newer).
-- Run:   the same data on both; node 1 on the older server, node 2 on the newer.
-- Expect: sp.x04_version_canary differs in row 21 (the version itself). Every
--         other difference is a value that the two versions compute or print
--         in another way: a finding. sp.x04_new_values holds values that only
--         a newer server can store: rows only on the newer node, and a repair
--         into the older node fails for them.
DROP TABLE IF EXISTS sp.x04_version_canary, sp.x04_new_values;
CREATE TABLE sp.x04_version_canary (id int PRIMARY KEY, what text, v text, f float8, n numeric, iv interval, ts timestamptz, j jsonb, tsv tsvector);
INSERT INTO sp.x04_version_canary (id, what, v) VALUES
	(1, 'float8 text', (0.1::float8 + 0.2::float8)::text),
	(2, 'float4 text', (0.1::float4)::text),
	(3, 'english stemmer', to_tsvector('english', 'The quick brown foxes were running generously')::text),
	(4, 'lower of special letters', lower(U&'\0130\01C5\1E9E')),
	(5, 'upper of special letters', upper(U&'\00DF\0149\01C6')),
	(6, 'initcap', initcap(U&'\01C6ungla o''neil mcdonald')),
	(7, 'hashtext', hashtext('abc')::text),
	(8, 'hashtextextended', hashtextextended('abc', 0)::text),
	(9, 'interval text', ('1 year 2 mons -3 days 04:05:06.789'::interval)::text),
	(10, 'time zone rules, 2026', ('2026-03-29 01:30:00+00'::timestamptz AT TIME ZONE 'Europe/Kyiv')::text),
	(11, 'time zone rules, 1900', ('1900-01-01 00:00:00+00'::timestamptz AT TIME ZONE 'Europe/Amsterdam')::text),
	(12, 'numeric power', (2::numeric ^ 0.5)::text),
	(13, 'numeric sqrt', sqrt(2::numeric)::text),
	(14, 'numeric exp', exp(1::numeric)::text),
	(15, 'float8 power', power(10::float8, -5)::text),
	(16, 'float8 sin', sin(1::float8)::text),
	(17, 'jsonb number', '{"a":1e2,"b":1.50}'::jsonb::text),
	(18, 'to_char', to_char(1234567.891, 'FM999G999G999D00')),
	(19, 'unicode normalize', normalize(U&'\00C5\FB01', NFKD)),
	(20, 'regexp word class', regexp_replace(U&'a\00E9\0431\4E2D_1 -', '\w', 'x', 'g')),
	(21, 'server version', current_setting('server_version_num')),
	(22, 'date arithmetic', age('2026-03-31'::timestamp, '2026-02-28'::timestamp)::text),
	(23, 'float8 round trip', (1e-7::float8)::text || ' ' || (123456789012345678::float8)::text),
	(24, 'string sort', (SELECT string_agg(s, ' ' ORDER BY s) FROM unnest(ARRAY['a-a','a+a','aa','A','B','b','_x','10','9']) s));
UPDATE sp.x04_version_canary SET f = 0.1::float8 + 0.2::float8, n = 2::numeric ^ 0.5, iv = '1 year 2 mons -3 days 04:05:06.789',
	ts = '2026-03-29 01:30:00+00', j = '{"a":1e2,"b":1.50}', tsv = to_tsvector('english', 'The quick brown foxes were running generously');
COMMENT ON TABLE sp.x04_version_canary IS 'X4: only row 21 should differ between two major versions';

CREATE TABLE sp.x04_new_values (id int PRIMARY KEY, what text, v text);
INSERT INTO sp.x04_new_values VALUES (0, 'plain row', 'same');
DO $$
BEGIN
	IF current_setting('server_version_num')::int >= 150000 THEN
		INSERT INTO sp.x04_new_values VALUES (15, 'numeric with a negative scale (15+)', (12345::numeric(3,-2))::text);
	END IF;
	IF current_setting('server_version_num')::int >= 160000 THEN
		INSERT INTO sp.x04_new_values VALUES (16, 'integer literal with underscores (16+)', ('1_000'::int)::text);
	END IF;
	IF current_setting('server_version_num')::int >= 170000 THEN
		INSERT INTO sp.x04_new_values VALUES (17, 'infinite interval (17+)', ('infinity'::interval)::text);
	END IF;
END $$;
COMMENT ON TABLE sp.x04_new_values IS 'X4: rows 15, 16, 17 exist only on a server that is new enough';
