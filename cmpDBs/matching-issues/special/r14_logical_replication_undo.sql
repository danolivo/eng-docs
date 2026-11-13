-- Case R14, cleanup. Run in the database of node 2 (the subscriber). It drops
-- the subscription without touching the slot on the publisher; the node 1
-- script drops the slot and the publication when it runs again.
-- To run the case again: this script on node 2, then the node 1 script, then
-- the node 2 script.
DO $$
BEGIN
	IF EXISTS (SELECT FROM pg_subscription WHERE subname = 'ace_ref_r14_sub' AND subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())) THEN
		ALTER SUBSCRIPTION ace_ref_r14_sub DISABLE;
		ALTER SUBSCRIPTION ace_ref_r14_sub SET (slot_name = NONE);
		DROP SUBSCRIPTION ace_ref_r14_sub;
	END IF;
END $$;
DROP TABLE IF EXISTS sp.r14_published;
