# Bounded sort: the planner and the executor decide separately

## Summary

PostgreSQL can run a Sort as a bounded top-N heapsort when a Limit above it needs only N rows. Whether that happens is decided by the executor at run time. The planner estimates the cost of the Sort on its own assumptions, and nothing in the plan ties the two decisions together. On current master they disagree in both directions: some Sorts are costed as bounded but executed as full sorts, and others are costed as full sorts but executed as bounded ones. The five queries below show each case on a single table, with default settings.

Tested on master at `27c844034f8` (October 2026), `-O2` build, default `work_mem` (4MB).

## How each side works

### Executor

At startup and on every rescan, `ExecLimit` computes the bound in `compute_tuples_needed()` as `count + offset`. It returns -1 (no bound) when there is no count or when the clause is `WITH TIES`. The bound is then pushed down by `ExecSetTupleBound()`, which descends only through a fixed list of nodes: `Sort` and `IncrementalSort` (which take the bound), `Append`, `MergeAppend`, a projecting `Result`, a `SubqueryScan` without a qual, `Gather` and `GatherMerge`. Any other node stops it.

A Sort that receives a bound passes `TUPLESORT_ALLOWBOUNDED` to tuplesort. Tuplesort switches to a bounded heap once it has actually seen more than `2 × bound` tuples, or more than `bound` when it runs out of memory. This uses the real tuple count, not an estimate.

### Planner

`grouping_planner()` computes `limit_tuples = count_est + offset_est` in `preprocess_limit()`, but only when both values are known constants. It then passes `limit_tuples` to `cost_sort()` in a few places: `create_ordered_paths()` for the query's own `ORDER BY`, Append and MergeAppend paths over the sole base relation, set-operation sorts, and the MIN/MAX subquery in `planagg.c`. Everywhere else, Sorts are costed with `limit_tuples = -1`.

`cost_tuplesort()` mirrors tuplesort's rule: it assumes a bounded heapsort, costed as `N · log2(2·limit)` comparisons instead of `N · log2(N)`, whenever the estimated input exceeds `2 × limit_tuples` or does not fit in `work_mem`.

### The gap

Neither `SortPath` nor the `Sort` plan node has a field that records whether the Sort is expected to be bounded. The planner's `limit_tuples` is a guess about what the executor will do, and the executor never looks at it. The two sides stay consistent only as long as two independently maintained sets of rules agree: where the planner applies `limit_tuples`, and where `ExecSetTupleBound()` can reach.

## Examples

Setup:

```sql
CREATE TABLE t AS
  SELECT (random() * 1e6)::int AS x, g AS id
  FROM generate_series(1, 1000000) g;
VACUUM ANALYZE t;
SET max_parallel_workers_per_gather = 0;
```

The baseline is consistent. The Sort is costed as bounded (startup cost 36089) and runs as a top-N heapsort:

```
EXPLAIN (ANALYZE, TIMING OFF, BUFFERS OFF, SUMMARY OFF)
SELECT * FROM t ORDER BY x LIMIT 10;

 Limit  (cost=36089.64..36089.67 rows=10 width=8) (actual rows=10.00 loops=1)
   ->  Sort  (cost=36089.64..38589.64 rows=1000000 width=8) (actual rows=10.00 loops=1)
         Sort Key: x
         Sort Method: top-N heapsort  Memory: 25kB
         ->  Seq Scan on t  (cost=0.00..14480.00 rows=1000000 width=8) (actual rows=1000000.00 loops=1)
```

A full sort of the same input is costed at 127812, about 3.5 times more. That is the size of the error in every case below.

### Costed as bounded, executed as a full sort

**1. `FETCH FIRST ... WITH TIES`.** `preprocess_limit()` computes `limit_tuples` without looking at `limitOption`, so the Sort is costed as bounded. At run time, `compute_tuples_needed()` returns -1 for `WITH TIES`, and the Sort sorts everything, spilling to disk:

```
SELECT * FROM t ORDER BY x FETCH FIRST 10 ROWS WITH TIES;

 Limit  (cost=36089.64..36089.67 rows=10 width=8) (actual rows=10.00 loops=1)
   ->  Sort  (cost=36089.64..38589.64 rows=1000000 width=8) (actual rows=11.00 loops=1)
         Sort Key: x
         Sort Method: external merge  Disk: 17704kB
```

The executor is right here: with ties, the number of rows needed is unknown in advance. The planner should not assume a bound.

**2. `FOR UPDATE`.** The LockRows node sits between Limit and Sort. `ExecSetTupleBound()` has no case for it, so the bound never reaches the Sort. `create_ordered_paths()` has already costed the Sort with the limit:

```
SELECT * FROM t ORDER BY x LIMIT 10 FOR UPDATE;

 Limit  (cost=36089.64..36089.77 rows=10 width=14) (actual rows=10.00 loops=1)
   ->  LockRows  (cost=36089.64..48589.64 rows=1000000 width=14) (actual rows=10.00 loops=1)
         ->  Sort  (cost=36089.64..38589.64 rows=1000000 width=14) (actual rows=10.00 loops=1)
               Sort Key: x
               Sort Method: external merge  Disk: 23528kB
```

Again the executor is right: LockRows skips rows that were deleted concurrently (`TM_Deleted` → `goto lnext` in `nodeLockRows.c`), so it may need more input rows than the Limit returns. Passing the bound through would be unsafe. The planner should not apply `limit_tuples` below a LockRows.

### Costed as a full sort, executed as bounded

**3. Generic plan with `LIMIT $1`.** A Param cannot be evaluated at plan time, so `limit_tuples` stays at -1. The planner falls back to the 10% `tuple_fraction` heuristic, which shows up as `rows=100000` on the Limit. At run time, the bound is 10:

```
PREPARE q(int8) AS SELECT * FROM t ORDER BY x LIMIT $1;
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, ...) EXECUTE q(10);

 Limit  (cost=127812.34..128062.34 rows=100000 width=8) (actual rows=10.00 loops=1)
   ->  Sort  (cost=127812.34..130312.34 rows=1000000 width=8) (actual rows=10.00 loops=1)
         Sort Key: x
         Sort Method: top-N heapsort  Memory: 25kB
```

**4. Generic plan with `OFFSET $1`.** This is the same effect with a constant LIMIT. An unknown offset disables `limit_tuples` entirely (`offset_est = -1`), even though the executor will add the actual offset to the count and bound the Sort anyway:

```
PREPARE q2(int8) AS SELECT * FROM t ORDER BY x LIMIT 10 OFFSET $1;
EXPLAIN (ANALYZE, ...) EXECUTE q2(0);    -- with force_generic_plan

 Limit  (cost=128062.34..128062.37 rows=10 width=8) (actual rows=10.00 loops=1)
   ->  Sort  (cost=127812.34..130312.34 rows=1000000 width=8) (actual rows=10.00 loops=1)
         Sort Key: x
         Sort Method: top-N heapsort  Memory: 25kB
```

**5. `ORDER BY` in a subquery, `LIMIT` outside.** A subquery with `ORDER BY` is not pulled up, so it is planned separately, with its own (absent) LIMIT. `set_subquery_pathlist()` passes the outer `tuple_fraction` down to such a subquery when it is the sole relation, but not `limit_tuples`. The trivial SubqueryScan is then removed, and the bound reaches the Sort directly:

```
SELECT * FROM (SELECT * FROM t ORDER BY x) s LIMIT 10;

 Limit  (cost=127812.34..127812.37 rows=10 width=8) (actual rows=10.00 loops=1)
   ->  Sort  (cost=127812.34..130312.34 rows=1000000 width=8) (actual rows=10.00 loops=1)
         Sort Key: t.x
         Sort Method: top-N heapsort  Memory: 25kB
```

### Summary of the examples

| Query | Sort startup cost | Executed as |
|---|---|---|
| `ORDER BY x LIMIT 10` (baseline) | 36 090 (bounded) | top-N heapsort |
| `FETCH FIRST 10 ROWS WITH TIES` | 36 090 (bounded) | external merge, 17.7 MB |
| `LIMIT 10 FOR UPDATE` | 36 090 (bounded) | external merge, 23.5 MB |
| generic `LIMIT $1` | 127 812 (full) | top-N heapsort |
| generic `LIMIT 10 OFFSET $1` | 127 812 (full) | top-N heapsort |
| subquery `ORDER BY`, outer `LIMIT 10` | 127 812 (full) | top-N heapsort |

A smaller, mostly harmless source of disagreement comes on top of these. The `2 × limit` rule is applied to estimated rows in the planner and to actual rows in tuplesort, so a row-count misestimate can make one side assume a heap and the other run a quicksort. When the input really is that small, either choice is cheap.

## Does it matter?

In the single-table queries above, the plan shape does not change, because there is no competing path. The effects are elsewhere.

`EXPLAIN` shows Sort costs that cannot be reconciled with `EXPLAIN ANALYZE`. In cases 1 and 2, the planner expects a 25kB heap and gets a multi-megabyte external sort.

The error feeds decisions higher up the plan tree. In case 5, the subquery's cost is overstated by about 3.5 times, and that inflated cost is what the outer query sees when it chooses join methods and join order around the subquery. In cases 1 and 2, the Sort looks cheaper than it is, so a seq scan plus sort can win against alternatives that would be cheaper than the real full sort, such as an incremental sort over a partially ordered index, or a different join strategy beneath the sort. I have not built a reproducer for a plan flip; these are the mechanisms through which one could happen.

Every new place where the executor learns to push a bound (new node types in `ExecSetTupleBound()`) widens the gap, unless the planner is taught the same rule at the same time.

## Possible directions

Two small planner-side fixes look safe. One is not to set `limit_tuples` for `WITH TIES`. The other is not to apply it when a LockRows node will sit between the Limit and the Sort, that is, when `parse->rowMarks` is non-empty.

The subquery case could be handled the same way `tuple_fraction` already is: pass the outer `limit_tuples` down to a sole-relation subquery whose output goes straight to the Limit.

For generic plans the bound is unknown by definition. The planner could at least treat a Param LIMIT as bounded, consistently with the 10% fraction it already assumes, instead of costing a full sort.

A more structural fix would make the decision explicit: record the planner's expected bound in the Sort node, or derive both the planner's `limit_tuples` placement and `ExecSetTupleBound()`'s descent from one shared rule, so that the two cannot drift apart.
