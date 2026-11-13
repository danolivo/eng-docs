-- Case R14: a repair on a node that publishes its changes by native logical
-- replication (no Spock, so no repair mode).
-- Stand: wal_level = logical on the publisher. Node 1 is the publisher, node 2
--        the subscriber; they can be two databases of one instance.
-- Run:   1. node 1 script in the publisher database;
--        2. EDIT THE CONNECTION STRING in the node 2 script (one line, marked
--           below), then run it in the subscriber database. It waits for the
--           first copy and then makes local changes on the subscriber.
-- Expect: diff: row 2 changed, row 3 only on node 2, row 4 only on node 1.
--   Repair with node 1 as the source writes only to the subscriber: fine.
--   Repair with node 2 as the source writes to the publisher: its INSERT of
--   row 3, UPDATE of row 2 and DELETE of row 4 are replicated to node 2. The
--   INSERT of row 3 hits the row that node 2 already has: the apply worker
--   fails with a duplicate key and the subscription stops. Check on node 2:
--     SELECT apply_error_count FROM pg_stat_subscription_stats;
-- To run the case again: r14_logical_replication_undo.sql on node 2, then the
-- node 1 script, then the node 2 script.
\if :n1
DO $$
BEGIN
	IF current_setting('wal_level') <> 'logical' THEN
		RAISE EXCEPTION 'this case needs wal_level = logical';
	END IF;
	IF EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'ace_ref_r14' AND active) THEN
		RAISE EXCEPTION 'the slot ace_ref_r14 is in use: run r14_logical_replication_undo.sql on node 2 first';
	END IF;
	PERFORM pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'ace_ref_r14';
END $$;
DROP PUBLICATION IF EXISTS ace_ref_r14_pub;
DROP TABLE IF EXISTS sp.r14_published;
CREATE TABLE sp.r14_published (id int PRIMARY KEY, v text);
INSERT INTO sp.r14_published VALUES (1, 'same'), (2, 'version of the publisher'), (4, 'deleted on the subscriber');
CREATE PUBLICATION ace_ref_r14_pub FOR TABLE sp.r14_published;
DO $$ BEGIN PERFORM pg_create_logical_replication_slot('ace_ref_r14', 'pgoutput'); END $$;
\else
DO $$
BEGIN
	IF EXISTS (SELECT FROM pg_subscription WHERE subname = 'ace_ref_r14_sub' AND subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())) THEN
		ALTER SUBSCRIPTION ace_ref_r14_sub DISABLE;
		ALTER SUBSCRIPTION ace_ref_r14_sub SET (slot_name = NONE);
		DROP SUBSCRIPTION ace_ref_r14_sub;
	END IF;
END $$;
DROP TABLE IF EXISTS sp.r14_published;
CREATE TABLE sp.r14_published (id int PRIMARY KEY, v text);
-- EDIT THE NEXT LINE: the connection string of the node 1 database.
CREATE SUBSCRIPTION ace_ref_r14_sub CONNECTION 'host=localhost port=5432 dbname=n1' PUBLICATION ace_ref_r14_pub
	WITH (create_slot = false, slot_name = 'ace_ref_r14', copy_data = true);
DO $$
BEGIN
	FOR i IN 1 .. 600 LOOP
		EXIT WHEN EXISTS (SELECT FROM pg_subscription_rel WHERE srrelid = 'sp.r14_published'::regclass AND srsubstate = 'r');
		PERFORM pg_sleep(0.1);
	END LOOP;
	IF NOT EXISTS (SELECT FROM pg_subscription_rel WHERE srrelid = 'sp.r14_published'::regclass AND srsubstate = 'r') THEN
		RAISE EXCEPTION 'the first copy of sp.r14_published did not finish in 60 s: check the connection string and the server log';
	END IF;
END $$;
-- Local changes of the subscriber. They are not sent back to the publisher.
UPDATE sp.r14_published SET v = 'version of the subscriber' WHERE id = 2;
INSERT INTO sp.r14_published VALUES (3, 'only on the subscriber');
DELETE FROM sp.r14_published WHERE id = 4;
\endif
COMMENT ON TABLE sp.r14_published IS 'R14: row 2 changed, row 3 only on node 2, row 4 only on node 1; node 1 publishes this table to node 2';
