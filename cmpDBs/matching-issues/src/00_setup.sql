-- Session settings, cleanup of an earlier run, extensions, schemas, roles and
-- the register of cases.
SET client_min_messages = warning;
SET client_encoding = 'UTF8';
SET TimeZone = 'UTC';
SET DateStyle = 'ISO, MDY';
SET IntervalStyle = 'postgres';
SET lc_monetary = 'C';
SET extra_float_digits = 1;
SET bytea_output = 'hex';
SET search_path = public;

DROP SCHEMA IF EXISTS ref_meta, num, typ, eqv, txt, nul, key, dty, lob, str, rep, ver, dmp CASCADE;
DROP SERVER IF EXISTS ace_ref_loopback CASCADE;
DO $$
DECLARE
	r record;
BEGIN
	FOR r IN SELECT oid FROM pg_largeobject_metadata WHERE oid BETWEEN 900000 AND 900999 LOOP
		PERFORM lo_unlink(r.oid);
	END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS lo;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Two roles for the cases about privileges (L7, S8, S9). Roles belong to the
-- whole instance, so they are created once and kept.
DO $$
BEGIN
	IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ace_ref_reader') THEN
		CREATE ROLE ace_ref_reader LOGIN;
	END IF;
	IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ace_ref_other') THEN
		CREATE ROLE ace_ref_other NOLOGIN;
	END IF;
END $$;

CREATE SCHEMA ref_meta;  -- register of cases, the same on every node
CREATE SCHEMA num;       -- numeric and float
CREATE SCHEMA typ;       -- types and table definitions
CREATE SCHEMA eqv;       -- equal by the operator, different text
CREATE SCHEMA txt;       -- text output, session, encoding
CREATE SCHEMA nul;       -- NULL and row encoding
CREATE SCHEMA key;       -- keys and block bounds
CREATE SCHEMA dty;       -- other data types
CREATE SCHEMA lob;       -- oid columns and large objects
CREATE SCHEMA str;       -- table structure, visibility, replication design
CREATE SCHEMA rep;       -- repair
CREATE SCHEMA ver;       -- verdict
CREATE SCHEMA dmp;       -- dump / restore / pg_upgrade scenario

-- One line for each pair (case, table). The text in "expect" says what a
-- correct comparison of node 1 and node 2 should report for this table.
CREATE TABLE ref_meta.cases (
	case_id text NOT NULL,
	tbl     text NOT NULL,
	expect  text NOT NULL,
	PRIMARY KEY (case_id, tbl)
);

CREATE PROCEDURE ref_meta.reg(text, text, text)
LANGUAGE sql
AS $$ INSERT INTO ref_meta.cases VALUES ($1, $2, $3) $$;
