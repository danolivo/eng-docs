# Quick slicing with only one touch of the index

## Proposal

```sql
SELECT key FROM (SELECT key, row_number() OVER (ORDER BY key) rn FROM t) s
WHERE rn % N = 0;
```

## An experiment

```sql
CREATE TEMP TABLE test (x INTEGER PRIMARY KEY, y numeric);
INSERT INTO test (x,y) SELECT gs, random() FROM generate_series(1,1E6) AS gs;
ANALYZE test;

EXPLAIN
SELECT x FROM (SELECT x, row_number() OVER (ORDER BY x) rn FROM test) s
WHERE rn % 1000 = 0;

```

## Issue with result delivery on client

With simple query we not sure when 

```sql
DECLARE pgcmp_slice NO SCROLL CURSOR FOR
SELECT "org_id"::integer::text, "doc_ref"::bytea::text
FROM (SELECT "org_id", "doc_ref",
             row_number() OVER (ORDER BY public.orders."org_id", public.orders."doc_ref") AS rn
      FROM public.orders
      WHERE (status <> 'archived')) s
WHERE rn % 100000 = 0
ORDER BY rn;

-- 2. в цикле, пока возвращается хотя бы одна строка
FETCH FORWARD 16 FROM pgcmp_slice;   -- 4 * jobs
-- ...
CLOSE pgcmp_slice;                    -- или просто конец транзакции
```