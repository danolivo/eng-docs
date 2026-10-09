# The B-tree index as live statistics for the optimizer

*Research report, October 2026. Sources are linked inline. Items marked **[unverified]** could not be confirmed from an opened source.*

## 1. Summary

- **The idea is old and it is in production.** Several systems read the index structure at plan time to estimate cardinality:
  - **MySQL / MariaDB (InnoDB)** do "index dives" for every range predicate.
  - **Oracle Rdb** (former DEC Rdb) has had "Index Estimation" from upper B-tree levels since the 1990s.
  - **Db2 10 for z/OS** has "Index Probing", which reads a few non-leaf pages.
  - **Oracle Database** probes an index inside dynamic sampling.
  - **SQL Server** and **CockroachDB** read the real index end values for ascending keys.
- **PostgreSQL already does a small part of this.** `get_actual_variable_range()` reads the real minimum or maximum from a B-tree when a constant falls at the edge of the histogram. This has existed since 9.0. Everything else comes from `pg_statistic`, which is only as fresh as the last ANALYZE.
- **One gap is open everywhere.** No system or paper found here reads the separator keys of the upper B-tree levels as a ready equi-depth histogram. Oracle Rdb and Antoshenkov (VLDB 1992) come closest: they count separators at the "split level" of a range.
- **Main opportunity for PostgreSQL.** Range estimates that read only internal B-tree pages:
  - they need no heap access and do not depend on visibility, which is the weak point of the current endpoint probe;
  - for a 3.8-billion-row bigint key, reading about 80 pages gives roughly 28,000 quantiles.
  - Section 7 lists eight concrete uses and their risks.

## 2. What a B-tree knows about the data

A PostgreSQL B-tree (nbtree) holds a lot of information about the data, and much of it is cheap to read.

| Information | Where it is | Cost to read |
|---|---|---|
| Tree height | metapage (`_bt_getrootheight`) | 1 page, already used by the planner |
| Leaf page count | relation size, minus internal pages | free (`RelationGetNumberOfBlocks`) |
| Key quantiles, by leaf pages | separator ("pivot") keys in internal pages | root + one level: tens of pages |
| Number of rows in a key range | two descents, then count separators at the split level | about 2 × height pages, mostly cached |
| Duplicates of a value | posting lists (deduplication, PG 13+); a value that spans several leaves | a descent, plus leaf pages for heavy values |
| Physical order of heap rows | heap TIDs in leaf tuples | sampled leaf pages |
| Dead entries | `LP_DEAD` hint bits on leaf items | sampled leaf pages |
| Recent growth at the right end | rightmost leaf and its parent | 1 descent |

Size example: a bigint primary key on 3.79 billion rows.

- A leaf holds about 400 tuples. Rightmost splits fill a page to 90%.
- This gives about 10 million leaves, about 28,000 pages at level 1, about 80 pages at level 2, and a root with about 80 entries.
- The root and level 2 together are about 80 pages (about 0.6 MB). They hold about 28,000 separators, one per ~135,000 rows.
- The default `pg_statistic` histogram has 100 buckets.

Separator keys are equi-depth by **pages, not rows**. Page fill varies from about 50% to 100%, depending on split history. So the size of a single bucket can be off by up to two times, but the error averages out over wider ranges.

Two nbtree details matter here:

- **Suffix truncation (PG 12+).** A pivot keeps only the key columns that are needed to tell its two neighbours apart. For a single-column key, the separator is a real key value. For a composite key, trailing columns can be "minus infinity".
- **No cleanup without VACUUM.** Separators of deleted keys stay until VACUUM removes the pages. Empty pages and dead entries move the estimates towards the old data.

## 3. Relational DBMS survey

| System | What it reads from the index | When | Key names |
|---|---|---|---|
| MySQL / InnoDB | Two root-to-leaf paths for the ends of each range. Counts the rows between them at each level and extrapolates from up to 10 pages per level. | Every plan with range access | `records_in_range`, `btr_estimate_n_rows_in_range`, `eq_range_index_dive_limit` (default 200) |
| MySQL / InnoDB (ANALYZE) | Picks a level above the leaves with enough distinct keys, then dives into A sampled groups. NDV = V × avg(Pi). | ANALYZE | WL#5520, `innodb_stats_persistent_sample_pages` (20) |
| MariaDB | Same index dives, plus real histograms (JSON_HB from 10.8). 50% cap on dive estimates removed in 11.0.1. | Every plan | MDEV-19424 |
| MyRocks | Approximate SST and memtable sizes for the key range | Every plan | `GetApproximateSizes` |
| Oracle Rdb | Descends to the split level. Estimate = `dup × seps × fan^(split_level−1)`, exact when the split level is the leaf. Ranked indexes store cardinality bounds per branch. | Run time and compile time | "Index Estimation (Estim)" |
| Oracle Database | Dynamic sampling sends a recursive query through an index with `ROWNUM <= 2500`, which gives an exact count for rare values. | Parse time, dynamic sampling | `OPT_DYN_SAMP`, patent US7213012B2 |
| Db2 10 z/OS | Counts RIDs in a start/stop key range from a few non-leaf pages. Used when stats say "0 rows", the table is empty, or the table is volatile. | Bind/run time | "Index Probing", `DSN_COLDIST_TABLE` |
| SQL Server | For ascending keys, compiles a query to read the highest value, then adds a histogram step. | Compile time | TF 2389/2390/4139, `ENABLE_HIST_AMENDMENT_FOR_ASC_KEYS` |
| Teradata | Reads the master index and the cylinder index to estimate table and index cardinality from one AMP. | No collected stats | Dynamic AMP sampling |
| SQLite | Estimates the row count from cell counts on one root-to-leaf path. | ANALYZE (limited), `sqlite_btreeinfo` | `sqlite3BtreeRowCountEst` |
| CockroachDB | Partial statistics on index extremes, merged with full stats. | Stats collection | `CREATE STATISTICS … USING EXTREMES` |
| Informix | Stores tree shape (levels, leaves, nunique, clust). | `UPDATE STATISTICS LOW` | `sysindices` |
| PostgreSQL | Real minimum or maximum from the index when a constant falls at the histogram edge. Tree height for descent cost. Current relation size. | Every plan | `get_actual_variable_range`, `btcostestimate`, `estimate_rel_size` |

### Lessons from MySQL, the largest user of index dives

**Accuracy is good, but the extrapolation has known bugs.**

- A hard-coded `n_rows * 2` "because our algorithm tends to underestimate" makes estimates for large ranges about two times too high. ([Bug #117164](https://bugs.mysql.com/bug.php?id=117164), 2025)
- InnoDB caps estimates at about 50% of the table. ([MDEV-19424](https://jira.mariadb.org/browse/MDEV-19424))

**The planning cost is real.**

- A 200-value IN list costs 1.3 ms with statistics and 29.9 ms with dives. ([Løland 2012](http://jorgenloland.blogspot.com/2012/04/on-queries-with-many-values-in-in.html))
- This is why `eq_range_index_dive_limit` exists, and why MySQL skips dives under single-index `FORCE INDEX`. ([MySQL blog 2017](https://dev.mysql.com/blog-archive/optimization-to-skip-index-dives-with-force-index/))
- A 2026 proposal adds sampled dives for long IN lists. ([Bug #120021](https://bugs.mysql.com/bug.php?id=120021))

**Concurrency.** A page split between the two descents gives a wrong result. The fix retries the dives and then falls back to a fixed guess. ([Bug #84366](https://bugs.mysql.com/bug.php?id=84366))

### Oracle Rdb, the closest earlier design

[Oracle Rdb Journal, "Predicate Estimation"](https://www.oracle.com/technetwork/database/database-technologies/rdb/predicate-estimation-129333.pdf) describes the method:

- Descend to the first node where the range covers more than one separator.
- Count those separators and multiply by the estimated fan-out of the levels below.
- With "ranked" indexes, the nodes store cardinality bounds for each branch, so the counts are close to exact. The table row count also comes from the tree.

The base is Antoshenkov's work: [VLDB 1992](https://www.vldb.org/conf/1992/P375.PDF), patent [US5875445](https://patents.google.com/patent/US5875445).

## 4. Academic publications

| Work | Key idea | Relevance |
|---|---|---|
| Olken, Rotem. *Random Sampling from B+ Trees.* VLDB 1989. [pdf](https://www.vldb.org/conf/1989/P269.PDF) | Uniform row sampling by random descent with acceptance/rejection, with no counts stored in the tree. | Sampling from a plain B-tree is possible, but rejection rates are high on real trees. |
| Antoshenkov. *Random Sampling from Pseudo-Ranked B+ Trees.* VLDB 1992. [pdf](https://www.vldb.org/conf/1992/P375.PDF) | Each node stores loose upper and lower bounds of branch cardinality, updated only when a bound is broken (about 1% update overhead). | Gives selectivity "even without random sampling" at the split level, and table cardinality at the root. |
| Srivastava, Lum. *TBSAM.* ICDE 1988. Ranked / counted B-trees. [notes](https://www.chiark.greenend.org.uk/~sgtatham/algorithms/cbtree.html) | Subtree counts give an exact range count in O(log n). | Exact estimates, but every insert must update the whole path, so concurrency suffers. |
| Zhao, Xie, Li. *AB-tree.* PVLDB 15(9), 2022. [pdf](https://www.vldb.org/pvldb/vol15/p1835-zhao.pdf) | An aggregate B-tree with concurrent updates and random sampling. | A modern answer to the concurrency cost of counted trees. |
| Hu, Qiao, Tao. *Independent Range Sampling.* PODS 2014. | t independent samples from a key range in O(log n + t). | Theory for "sample this range" without a full scan. |
| Hellerstein, Haas, Wang. *Online Aggregation.* SIGMOD 1997. | "Index striding": round-robin fetches through an index across groups. | Uses an index as a sampling device. |
| Chaudhuri, Motwani, Narasayya. *On Random Sampling over Joins.* SIGMOD 1999. | Samples a join through indexes on the inner relation. | Join estimates from indexes. |
| Li, Wu, Yi, Zhao. *Wander Join.* SIGMOD 2016 (best paper). [pdf](https://cse.hkust.edu.hk/~yike/sigmod16.pdf) | Random walks through join indexes with Horvitz-Thompson estimators. Prototyped in PostgreSQL. | Index-based join cardinality with no stored statistics. |
| Leis et al. *Cardinality Estimation Done Right: Index-Based Join Sampling.* CIDR 2017. [pdf](https://www.cidrdb.org/cidr2017/papers/p9-leis-cidr17.pdf) | Extends base-table samples through join indexes at optimization time. | The strongest evidence that index-based estimates improve plans. |
| Kraska et al. *The Case for Learned Index Structures.* SIGMOD 2018. [arXiv](https://arxiv.org/pdf/1712.01208) | An index is a model from key to position, so a range count is pos(hi) − pos(lo). | Index and CDF are the same object. |
| Li, Wang, Liu. *CardIndex.* SIGMOD 2024. [arXiv](https://export.arxiv.org/abs/2305.17674) | One learned structure is both an index and a cardinality estimator. | The clearest "index = estimator" design. |

**Not found:** a paper that treats the separator keys of a plain B-tree as an equi-depth histogram. A survey points to Lin et al., *JISE* 31(5), 2015, as "similar to the idea of the B-tree index". **[unverified]**

## 5. Blogs and mailing lists

**MySQL**

- Jørgen Løland (2012, 2014) explains the trade-off between dives and statistics, and the change of the dive limit from 10 to 200.
- Bug threads by Percona engineers (Laurynas Biveinis) and by Øystein Grøvlen (2026) show that the area is still active.

**PostgreSQL, in time order:**

- **2005.** Josh Berkus on "Bad n_distinct estimation": *"Unless, of course, we use indexes for sampling, which seems like a really good idea."* Mischa Sandberg pointed to Antoshenkov and DEC Rdb in reply. ([message](https://www.postgresql.org/message-id/1115175136.427838e0ae263%40webmail.telus.net))
- **2010.** Tom Lane adds `get_actual_variable_range` for 9.0 and decides not to use it in `mergejoinscansel`, to keep index fetches out of join estimation. ([thread](https://hackorum.dev/topics/23567))
- **2013.** Merge join planning takes 55 s because of repeated endpoint probes. Ideas from the thread: a min/max cache, and concern about mixing index values with `pg_statistic` values. ([message](https://www.postgresql.org/message-id/7139.1375472605%40sss.pgh.pa.us))
- **2013.** Btree descent cost is changed to use the root height. ([commit message](https://www.postgresql.org/message-id/E1Ttiqy-00014b-Aw%40gemulon.postgresql.org))
- **2022.** "Damage control for planner's get_actual_variable_endpoint() runaway". The result is `VISITED_PAGES_LIMIT = 100` heap pages, back-patched to all supported branches. Tom Lane: *"the entire mechanism exists only because of user complaints about inaccurate estimates."* ([message](https://www.postgresql.org/message-id/3122555.1669044748%40sss.pgh.pa.us))
- **2026.** Mark Callaghan measures that the overhead of `get_actual_variable_range` in an insert benchmark grew by 10% from PG 14 to 18. ([Small Datum](https://smalldatum.blogspot.com/2026/01/cpu-bound-insert-benchmark-vs-postgres.html))
- **2026.** Peter Geoghegan, "Problems with get_actual_variable_range's VISITED_PAGES_LIMIT". The limit counts only heap pages, so an index with many `LP_DEAD` items can make the probe read leaf pages without any limit. He calls it "the Achilles' heel for Postgres" in that benchmark. Tom Lane suggests a limit on skipped dead entries instead. At the time of writing, the patch with `INDEX_PAGES_LIMIT 3` is not committed. ([thread](https://www.postgresql.org/message-id/CAH2-Wzkt1WkKp4VRJu3qHfmKXc8W+XYv1RXg5d2d3fSvAeO=rg@mail.gmail.com))
- **Skip scan (PG 18).** `btcostestimate` multiplies the ndistinct of the skipped columns from `pg_statistic`. Geoghegan notes that it does not account for skew in ndistinct, and Tomas Vondra notes underestimates for independent columns. ([Geoghegan 2024](https://www.postgresql.org/message-id/CAH2-Wz=PKR6rB7qbx+Vnd7eqeB5VTcrW=iJvAsTsKbdG+kW_UA@mail.gmail.com))

**Not found:** a pgsql-hackers proposal for MySQL-style range dives, or for an ndistinct estimate taken from the B-tree.

## 6. What PostgreSQL takes from indexes today

1. **Endpoints.** `ineq_histogram_selectivity()` calls `get_actual_variable_range()` when the search hits the first or the last histogram bucket. The probe is an index scan and **must check visibility in the heap**. That is the source of the runaway cases, and the reason for `VISITED_PAGES_LIMIT`.
2. **Descent cost.** `btcostestimate()` charges `ceil(log2(tuples)) × cpu_operator_cost` and `(tree_height + 1) × 50 × cpu_operator_cost` per descent. `tree_height` comes from `amgettreeheight` (PG 18 API; before that, `_bt_getrootheight`).
3. **Size.** `estimate_rel_size()` scales the `reltuples / relpages` density by the **current** number of pages. So table growth is partly visible without ANALYZE, but changes in density are not.
4. **Uniqueness.** `var_eq_const()` returns `1 / ntuples` for an equality on a unique index.
5. **Expression indexes.** ANALYZE collects statistics on index expressions. This uses the index definition, not the index data.
6. **Extension hooks.** `get_relation_stats_hook` and `get_index_stats_hook` can replace the `pg_statistic` tuple that the planner sees.

All other estimates come from `pg_statistic`: the 100-bucket histogram, MCVs, `n_distinct` and `correlation`, plus `reltuples` and extended statistics. They are only as fresh as the last ANALYZE, and they are built from a sample of 300 × `statistics_target` rows.

## 7. What PostgreSQL could take from a B-tree

Each idea lists the estimation problem, what the index gives, and the cost. All ideas that read **only internal pages** avoid the visibility problem that hurts `get_actual_variable_endpoint()`. Separators are just keys; they are never checked against the heap.

### 7.1 Range selectivity by dives over internal pages

**Problem.** In `ineq_histogram_selectivity()`, a range inside one histogram bucket gets a linear interpolation through `convert_to_scalar()`. This is wrong for skewed data, wrong for non-numeric types, and wrong after data changes since ANALYZE.

**Index.** Descend for `lo` and `hi` until the paths split. At the split level, count the separators between the two paths and multiply by the average subtree size. The average comes from leaf pages × tuples per leaf, divided by the number of pages on that level. This is the Rdb method. It reads no leaf pages, unless the split happens at the leaf level, where an exact count is cheap anyway.

**Cost.** About 2 × height pages, and the upper levels are almost always in shared buffers.

**When to use.** Not always. Use it when:

- `n_mod_since_analyze` is high compared with `reltuples`;
- the range falls inside a single histogram bucket;
- the constant is outside the histogram;
- the column has no statistics at all.

### 7.2 A live histogram from the upper levels

**Problem.** The histogram is old, has only 100 buckets, and comes from a sample of 30,000 rows.

**Index.** Reading the root plus one level gives hundreds to tens of thousands of quantiles (see the example in section 2). This can be a cached "index histogram", rebuilt when the relation size changes by more than some fraction.

This needs no core change for a first experiment. An extension can use `get_relation_stats_hook` to build a `pg_statistic`-like tuple from these separators, and test plan quality against the ANALYZE histogram.

**Limits.**

- Buckets are equi-depth by pages, not rows.
- Page fill varies.
- Dead keys stay until VACUUM.
- Most common values are not separated out. A very common value shows up as many equal separators in a row. This is actually useful: see 7.4.

### 7.3 Composite indexes as multi-column statistics

**Problem.** For `a = 1 AND b > 5`, the planner multiplies selectivities as if the columns were independent, unless someone created extended statistics. Extended statistics have no multi-column histograms for ranges.

**Index.** An index on `(a, b)` holds the **joint** distribution in key order. A dive for `(1, 5)` .. `(1, +∞)` counts exactly the rows that match the conjunction. This works for any prefix of the index columns, with equality on the leading columns and a range on the next column.

**Value.** It fixes the most common correlated-columns misestimate on tables that already have the right index. These are often the queries where the choice between the index path and other paths matters most.

### 7.4 Frequencies of values not in the MCV list

**Problem.** For a constant that is not in the MCV list, `var_eq_const()` returns `(1 − Σ mcv − nullfrac) / (ndistinct − n_mcv)`. A value that became popular after ANALYZE gets this tiny average. Examples: a new `status`, today's `tenant_id`.

**Index.** An equality dive gives the number of leaf pages and separators that the value spans. If the value covers whole subtrees, the estimate is large and close to correct. If it stays inside one leaf, it is rare, and an exact count of that one leaf is cheap.

**Cost.** One descent per constant. This needs a limit similar to `eq_range_index_dive_limit` for long IN lists.

### 7.5 ndistinct of key prefixes

**Problem.**

- `n_distinct` from a 30,000-row sample is often wrong by orders of magnitude on large tables.
- PG 18 skip scan costing multiplies per-column ndistinct and does not see skew.
- GROUP BY and DISTINCT estimates have the same weakness.

**Index.**

- Use the InnoDB WL#5520 method: choose a level with enough distinct prefixes, sample leaves under "non-boring" separators, and extrapolate.
- Deduplication (PG 13+) helps: a posting list is a group of equal keys, so one leaf page shows directly how many distinct values it holds.
- For skip scan, a dive can count the distinct leading values **within the scanned range**. This answers the question the cost model asks, not only an average over the whole table.

### 7.6 Local correlation and clustering

**Problem.**

- `pg_statistic.correlation` is one number for the whole column.
- An append-only table is often well ordered in its recent part and disordered in its old part, or the other way around.
- Index scan cost (the Mackert-Lohman formula in `cost_index()`) uses this one global number for every range.

**Index.** Leaf tuples carry heap TIDs. Sample a few leaf pages **inside the scanned range** and measure how ordered the block numbers are. This is a per-range clustering factor, similar to Oracle `CLUSTERING_FACTOR`, but local.

**Cost.** A few leaf pages per costed index path, with no heap access.

### 7.7 Table size and growth

**Problem.** `reltuples` changes only on VACUUM and ANALYZE. Current pages × old density fails when the density changes, for example after bulk deletes or HOT updates.

**Index.** The primary key leaf count times the average tuples per leaf (from a few sampled leaves) gives an independent row count, which can be cross-checked with the heap estimate. The rightmost path also shows growth beyond the histogram, which is the case SQL Server and CockroachDB handle with their "ascending key" logic.

### 7.8 Join estimates through indexes (more expensive)

**Problem.** Join selectivity from `eqjoinsel()` uses MCV lists and ndistinct of both sides, and it is the largest source of error in multi-join queries.

**Index.** Following Leis et al. (2017) and Wander Join, take a small sample of outer values and dive into the inner index for each. This gives a direct estimate of matches per outer row.

**Cost.** Too high for every query. It could work like JIT, enabled only when the estimated plan cost is above a threshold.

### 7.9 How it could fit into PostgreSQL

**API.** A new optional index AM callback, for example `amestimaterange(indexRel, scankeys, nkeys) → (rows, confidence)`. Only nbtree would implement it at first. `clauselist_selectivity()` and `btcostestimate()` would call it when the statistics are suspect, and the result would replace the histogram-based selectivity for the matching clauses.

**Budget.**

- A per-query limit on index pages read during planning, counted like `VISITED_PAGES_LIMIT`, but for index pages.
- Only internal pages by default.
- A GUC to switch it off.

**Locks.** The planner already takes `AccessShareLock` on every index in `get_relation_info()`. Reading internal pages needs only buffer pins and share locks, as in a normal descent.

**Concurrency.** Page splits during a descent are handled by right-links (Lehman-Yao). An estimate can tolerate a missed split, so there is no need for the retry logic MySQL had to add.

**Hot standby.** Works, because the operation is read-only.

### 7.10 Risks

1. **Planning time.** This is the main cost, as MySQL shows (30 ms for 200 dives) and as the PostgreSQL history of `get_actual_variable_range` shows. Upper levels are cached, but the CPU cost per descent is not zero.
2. **Plan stability.**
   - Estimates now change with live data, so the same query can get a different plan without ANALYZE.
   - Regression tests that depend on plans become less stable.
   - Generic plans of prepared statements do not benefit, because the constants are unknown.
3. **Mixed sources.** Tom Lane raised this in 2013: if one selectivity comes from the index and another comes from `pg_statistic`, they describe different moments in time, and their combination can be inconsistent.
4. **Bloat.** Dead keys and half-empty pages distort page-based estimates until VACUUM. A cheap correction is to sample `LP_DEAD` bits, but leaves are not always in memory.
5. **Index types.** Only B-tree (and possibly BRIN, through its block ranges) gives this structure. GiST, GIN and hash indexes do not.

## 8. Link back to ACE

For ACE "parts" (stage 2.1), the separators at the root and the level below it are the ideal source: fresh, decorrelated from heap order, and cheap. But SQL cannot read them without `pageinspect`, which by default needs superuser. A small SQL-callable function in a pgEdge extension on the node, returning the separators at level *L*, would give ACE exact page-equal parts and would also serve as a prototype for idea 7.2.
