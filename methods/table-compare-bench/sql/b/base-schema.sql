-- Family B, step 1 (n1 and n2): unlogged base tables.
--
-- The base tables hold the random data once; the key variants are built from
-- them on each node with ORDER BY id, so both nodes get the same contents and
-- the same physical order. They are dropped before the final VACUUM.
\set ON_ERROR_STOP 1
DROP TABLE IF EXISTS base_narrow, base_wide, base_toast;
CREATE UNLOGGED TABLE base_narrow (id bigint, r numeric, h text, v bigint);
CREATE UNLOGGED TABLE base_wide   (id bigint, r numeric, h text, v bigint, pad text);
CREATE UNLOGGED TABLE base_toast  (id bigint, r numeric, h text, v bigint, payload text);
ALTER TABLE base_toast ALTER COLUMN payload SET STORAGE EXTERNAL;
