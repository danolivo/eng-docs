-- OID columns and large objects: L1 .. L14.
-- The large objects use the OIDs 900001 .. 900199.

-- L1: the object exists on n1 only; the rows are the same.
CREATE TABLE lob.l01_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l01_doc VALUES (1, 'contract', 900001);
\if :n1
DO $$ BEGIN PERFORM lo_from_bytea(900001, 'scan of the contract'); END $$;
\endif
CALL ref_meta.reg('L1', 'lob.l01_doc', 'rows match, but the object 900001 is missing on n2: lo_get(scan) fails there. A "match" here is a gap');

-- L2: the same OID, other content.
CREATE TABLE lob.l02_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l02_doc VALUES (1, 'invoice', 900002);
\if :n1
DO $$ BEGIN PERFORM lo_from_bytea(900002, 'scan of the invoice, version 2'); END $$;
\else
DO $$ BEGIN PERFORM lo_from_bytea(900002, 'scan of the invoice, version 1'); END $$;
\endif
CALL ref_meta.reg('L2', 'lob.l02_doc', 'rows match, the content of the object 900002 differs. A "match" here is a gap');

-- L3: the same OIDs hold the scans of other documents.
CREATE TABLE lob.l03_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l03_doc VALUES (1, 'passport of A', 900003), (7, 'passport of B', 900004);
\if :n1
DO $$ BEGIN PERFORM lo_from_bytea(900003, 'passport of A'); PERFORM lo_from_bytea(900004, 'passport of B'); END $$;
\else
DO $$ BEGIN PERFORM lo_from_bytea(900003, 'passport of B'); PERFORM lo_from_bytea(900004, 'passport of A'); END $$;
\endif
CALL ref_meta.reg('L3', 'lob.l03_doc', 'rows match, but on n2 each document points to the scan of the other one');

-- L4: other OID, the same content.
CREATE TABLE lob.l04_doc (id int PRIMARY KEY, title text, scan oid);
\if :n1
INSERT INTO lob.l04_doc VALUES (1, 'report', 900005);
DO $$ BEGIN PERFORM lo_from_bytea(900005, 'scan of the report'); END $$;
\else
INSERT INTO lob.l04_doc VALUES (1, 'report', 900105);
DO $$ BEGIN PERFORM lo_from_bytea(900105, 'scan of the report'); END $$;
\endif
CALL ref_meta.reg('L4', 'lob.l04_doc', 'row 1 changed (scan 900005 / 900105), the content is the same; repair from n1 writes 900005 to n2, where no such object exists');

-- L5: dangling and empty references.
CREATE TABLE lob.l05_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l05_doc VALUES (1, 'dangling on both', 900999), (2, 'zero', 0), (3, 'null', NULL);
\if :n1
INSERT INTO lob.l05_doc VALUES (4, 'null / zero', NULL);
\else
INSERT INTO lob.l05_doc VALUES (4, 'null / zero', 0);
\endif
CALL ref_meta.reg('L5', 'lob.l05_doc', 'rows 1-3 equal, row 4 changed (NULL / 0)');

-- L6: the lo domain with the lo_manage trigger.
CREATE TABLE lob.l06_doc_lo (id int PRIMARY KEY, title text, scan lo);
CREATE TABLE lob.l06_doc_lo_always (id int PRIMARY KEY, title text, scan lo);
\if :n1
INSERT INTO lob.l06_doc_lo VALUES (1, 'changed', 900006), (3, 'only n1', 900008);
INSERT INTO lob.l06_doc_lo_always VALUES (1, 'changed', 900010), (3, 'only n1', 900012);
DO $$ BEGIN
	PERFORM lo_from_bytea(900006, 'new scan'); PERFORM lo_from_bytea(900008, 'scan 3');
	PERFORM lo_from_bytea(900010, 'new scan'); PERFORM lo_from_bytea(900012, 'scan 3');
END $$;
\else
INSERT INTO lob.l06_doc_lo VALUES (1, 'changed', 900106), (2, 'only n2', 900107);
INSERT INTO lob.l06_doc_lo_always VALUES (1, 'changed', 900110), (2, 'only n2', 900111);
DO $$ BEGIN
	PERFORM lo_from_bytea(900106, 'old scan'); PERFORM lo_from_bytea(900107, 'scan 2');
	PERFORM lo_from_bytea(900110, 'old scan'); PERFORM lo_from_bytea(900111, 'scan 2');
END $$;
\endif
CREATE TRIGGER l06_manage BEFORE UPDATE OR DELETE ON lob.l06_doc_lo FOR EACH ROW EXECUTE FUNCTION lo_manage(scan);
CREATE TRIGGER l06_manage BEFORE UPDATE OR DELETE ON lob.l06_doc_lo_always FOR EACH ROW EXECUTE FUNCTION lo_manage(scan);
ALTER TABLE lob.l06_doc_lo_always ENABLE ALWAYS TRIGGER l06_manage;
CALL ref_meta.reg('L6', 'lob.l06_doc_lo', 'row 1 changed, row 3 only on n1, row 2 only on n2. A repair n1 -> n2 that fires triggers unlinks the objects 900106 and 900107 on n2; a repair that does not fire them leaves these objects as orphans. The objects 900006 and 900008 are never created on n2');
CALL ref_meta.reg('L6', 'lob.l06_doc_lo_always', 'as l06_doc_lo, but the trigger is ENABLE ALWAYS: the objects 900110 and 900111 are unlinked in every mode');

-- L7: the owner and the privileges of an object differ.
CREATE TABLE lob.l07_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l07_doc VALUES (1, 'secret', 900013);
DO $$ BEGIN PERFORM lo_from_bytea(900013, 'secret scan'); END $$;
\if :n1
GRANT SELECT ON LARGE OBJECT 900013 TO ace_ref_reader;
\else
ALTER LARGE OBJECT 900013 OWNER TO ace_ref_other;
\endif
CALL ref_meta.reg('L7', 'lob.l07_doc', 'rows and content match; on n2 the object belongs to another role and ace_ref_reader cannot read it');

-- L8: the pages of a document kept in an ordinary table.
CREATE TABLE lob.l08_pages (doc_id int, pageno int, data bytea, PRIMARY KEY (doc_id, pageno));
INSERT INTO lob.l08_pages SELECT d, p, convert_to(repeat(md5(d::text || '/' || p::text), 64), 'UTF8') FROM generate_series(1, 20) d, generate_series(0, 9) p;
\if :n2
DELETE FROM lob.l08_pages WHERE (doc_id, pageno) = (3, 9);
UPDATE lob.l08_pages SET data = data || '\x00' WHERE (doc_id, pageno) = (7, 0);
\endif
CALL ref_meta.reg('L8', 'lob.l08_pages', 'page (7, 0) changed, page (3, 9) only on n1: the content is in a table, so it is compared');

-- L9: the same content in another page layout.
CREATE TABLE lob.l09_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l09_doc VALUES (1, 'sparse', 900014);
\if :n1
DO $$ BEGIN PERFORM lo_create(900014); PERFORM lo_put(900014, 10000, 'tail'); END $$;
\else
DO $$ BEGIN PERFORM lo_from_bytea(900014, decode(repeat('00', 10000), 'hex') || 'tail'); END $$;
\endif
CALL ref_meta.reg('L9', 'lob.l09_doc', 'rows match and lo_get() gives the same bytes; pg_largeobject holds 1 page on n1 and 5 pages on n2');

-- L10: positive control, the same OID and the same content.
CREATE TABLE lob.l10_doc (id int PRIMARY KEY, title text, scan oid);
INSERT INTO lob.l10_doc VALUES (1, 'good one', 900015), (2, 'good two', 900016);
DO $$ BEGIN PERFORM lo_from_bytea(900015, 'the same scan'); PERFORM lo_from_bytea(900016, convert_to(repeat('page ', 5000), 'UTF8')); END $$;
CALL ref_meta.reg('L10', 'lob.l10_doc', 'match, and the objects are the same too');
-- L11: the catalogs that hold the large objects.
CALL ref_meta.reg('L11', 'pg_catalog.pg_largeobject', 'the content of all objects above; differs for 900001-900014 and the 9001xx objects. No primary key constraint: refused with a clear message, or compared');
CALL ref_meta.reg('L11', 'pg_catalog.pg_largeobject_metadata', 'owners and privileges of the objects');
-- P6: large objects after a dump and restore.
CALL ref_meta.reg('P6', 'lob.l01_doc', 'large objects after a dump of one table: see L1, L3, L7, L9, L10');

-- L12: a plain column of type oid.
CREATE TABLE lob.l12_oid_col (id int PRIMARY KEY, ref oid, refs oid[]);
INSERT INTO lob.l12_oid_col VALUES (0, 16384, '{1,2}');
\if :n1
INSERT INTO lob.l12_oid_col VALUES (1, 16385, '{1,4294967295}'), (2, 4294967295, '{}');
\else
INSERT INTO lob.l12_oid_col VALUES (1, 16386, '{1,4294967294}');
\endif
CALL ref_meta.reg('L12', 'lob.l12_oid_col', 'row 1 changed, row 2 only on n1; the value 4294967295 comes back unchanged');

-- L13: oid as a key, with values above 2^31.
CREATE TABLE lob.l13_oid_key (id oid PRIMARY KEY, v text);
INSERT INTO lob.l13_oid_key VALUES (1, 'same'), (2147483647, 'same');
\if :n1
INSERT INTO lob.l13_oid_key VALUES (2147483648, 'n1'), (4294967295, 'n1'), (3000000000, 'only n1');
\else
INSERT INTO lob.l13_oid_key VALUES (2147483648, 'n2'), (4294967295, 'n2');
\endif
CALL ref_meta.reg('L13', 'lob.l13_oid_key', 'keys 2147483648 and 4294967295 changed, key 3000000000 only on n1; oid is unsigned');

-- L14: reg* columns.
CREATE TABLE lob.l14_target (id int PRIMARY KEY);
CREATE TABLE lob.l14_reg (id int PRIMARY KEY, rc regclass, rt regtype, rp regproc, rr regrole, rcfg regconfig, rns regnamespace);
INSERT INTO lob.l14_reg VALUES (1, 'lob.l14_target', 'int4', 'now', 'ace_ref_reader', 'english', 'lob'), (2, 'pg_class', 'text', 'version', 'ace_ref_other', 'simple', 'pg_catalog');
\if :n1
CREATE TABLE lob.l14_only_n1 (id int PRIMARY KEY);
INSERT INTO lob.l14_reg VALUES (3, 'lob.l14_only_n1', 'int8', 'pg_backend_pid', 'ace_ref_reader', 'english', 'lob');
\endif
CALL ref_meta.reg('L14', 'lob.l14_reg', 'rows 1, 2 equal by name (the OID behind lob.l14_target differs); row 3 only on n1; repair fails on n2: relation lob.l14_only_n1 does not exist');
