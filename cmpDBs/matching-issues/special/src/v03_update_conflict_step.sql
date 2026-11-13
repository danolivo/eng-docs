-- Case V3, step 2: see v03_update_conflict. Run after mtree build.
\if :n1
UPDATE sp.v03_conflict SET v = 'updated on node 1' WHERE id IN (10000, 25000, 50000, 75000, 99990);
INSERT INTO sp.v03_conflict SELECT i * 10 + 5, 'new on node 1' FROM generate_series(2000, 2499) i;
\else
UPDATE sp.v03_conflict SET v = 'updated on node 2' WHERE id IN (10000, 25000, 50000, 75000, 99990);
DELETE FROM sp.v03_conflict WHERE id BETWEEN 70000 AND 74990;
\endif
