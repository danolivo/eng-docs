-- Hot-cache regime: read a table and its primary key first into the OS page
-- cache ('read'), then into shared_buffers ('buffer'). Run on both nodes before
-- a series on that table.
--
--   psql -v tbl=narrow -f prewarm.sql
--   psql -v tbl=narrow -v mode=read -f prewarm.sql   page cache only
--                                                    (constrained shared_buffers)
--
-- A table larger than shared_buffers keeps only the part read last; the rest
-- is served from the page cache. "Hot" means "in the node's RAM", not "in
-- shared_buffers".
\set ON_ERROR_STOP 1
\if :{?mode}
\else
  \set mode both
\endif
CREATE EXTENSION IF NOT EXISTS pg_prewarm;

SELECT i.indexrelid::regclass AS pk FROM pg_index i
 WHERE i.indrelid = :'tbl'::regclass AND i.indisprimary \gset

SELECT 'read' AS pass, pg_prewarm(:'tbl', 'read') AS heap_blocks, pg_prewarm(:'pk', 'read') AS pk_blocks;
SELECT :'mode' <> 'read' AS do_buffer \gset
\if :do_buffer
SELECT 'buffer' AS pass, pg_prewarm(:'tbl', 'buffer') AS heap_blocks, pg_prewarm(:'pk', 'buffer') AS pk_blocks;
\endif
