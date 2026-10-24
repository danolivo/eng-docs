-- Family B, step 6 (n1 and n2): drop the base tables before the final VACUUM.
\set ON_ERROR_STOP 1
DROP TABLE IF EXISTS base_narrow, base_wide, base_toast;
