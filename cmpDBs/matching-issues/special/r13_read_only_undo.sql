-- Case R13, cleanup: make the database of node 2 writable again.
-- Run in the database where r13_read_only_node2.sql was run.
SET default_transaction_read_only = off;
DO $$ BEGIN EXECUTE format('ALTER DATABASE %I RESET default_transaction_read_only', current_database()); END $$;
