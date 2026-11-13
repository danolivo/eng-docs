-- Privileges of the test role and statistics.
GRANT USAGE ON SCHEMA ref_meta, num, typ, eqv, txt, nul, key, dty, lob, str, rep, ver, dmp TO ace_ref_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA ref_meta, num, typ, eqv, txt, nul, key, dty, lob, str, rep, ver, dmp TO ace_ref_reader;
\if :n2
-- S9: no access to the column "secret" on node 2.
REVOKE SELECT ON str.s09_col_priv FROM ace_ref_reader;
GRANT SELECT (id, public_v) ON str.s09_col_priv TO ace_ref_reader;
\endif
ANALYZE;
\if :n2

-- Optional, case X2: give the database of node 2 other session defaults.
-- A tool that does not pin its own settings then sees differences in
-- txt.x02_session and in every table with dates, intervals, bytea or money.
-- Put the name of the database and run by hand. The locale of lc_monetary
-- must exist on the server ("locale -a"); any locale but C will do.
--
--   ALTER DATABASE mydb SET TimeZone = 'Asia/Tokyo';
--   ALTER DATABASE mydb SET DateStyle = 'SQL, DMY';
--   ALTER DATABASE mydb SET IntervalStyle = 'sql_standard';
--   ALTER DATABASE mydb SET bytea_output = 'escape';
--   ALTER DATABASE mydb SET extra_float_digits = 0;
--   ALTER DATABASE mydb SET lc_monetary = 'de_DE.UTF-8';
\endif
