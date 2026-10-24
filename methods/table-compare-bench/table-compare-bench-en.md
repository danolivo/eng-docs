# Benchmarking table comparison tools: method and data

How to build the test databases and run a comparison of pgcmp, ACE,
pg_comparator and pgCompare on the three table shapes **narrow**, **wide**
and **toast**. This method is assembled from the October 2026 trials
(pilot, main trial, composite-key trial, cold-cache trial and
parallel-tuning trial) and from what went wrong in them. Shell orchestration is not
part of it; the few loops you need are shown inline.

Contents:

1. [What is measured](#1-what-is-measured)
2. [Test bed](#2-test-bed)
3. [Data](#3-data)
4. [Building the data](#4-building-the-data)
5. [Physical state of the tables: layout and visibility map](#5-physical-state-of-the-tables-layout-and-visibility-map)
6. [Cache regimes](#6-cache-regimes)
7. [Run protocol](#7-run-protocol)
8. [Known pitfalls](#8-known-pitfalls)
9. [Files](#9-files)

## 1. What is measured

Two PostgreSQL nodes hold the same tables, with a known set of differences on
the second one. Each tool compares the tables from a separate client machine.
For every run we record:

| metric | source |
|---|---|
| wall time | the client |
| client CPU (user + sys), peak RSS | `/usr/bin/time -v` |
| node CPU, busy-seconds | `/proc/stat` deltas on n1 and n2 |
| bytes received by the client | interface counters on the client |
| disk reads on the nodes | `/proc/diskstats` of the data array (md0) |
| heap hit / read | deltas of `pg_statio_user_tables` on each node |
| found / expected, false positives | the tool's report against the ground truth table `gt` |
| table state | `vm-check.sql` and `layout.sql` output on both nodes (section 5) |

The last row is new. Without it, two runs of the same tool on "the same" data
are not comparable (see 5.2).

## 2. Test bed

| role | machine (as used) | disks |
|---|---|---|
| n1 (reference), n2 (test) | GCE n2-highmem-16: 16 vCPU, 128 GB | local NVMe, RAID0, XFS, `noatime` |
| client: all tools, the pgCompare repository | GCE c4-standard-32: 32 vCPU, 128 GB | hyperdisk-balanced 200–500 GB |

All three machines are in one zone and connect over internal IPs.
PostgreSQL 18.6 on the nodes, cluster with `--locale=C.UTF-8 --encoding=UTF8`.
Node settings:

```
shared_buffers = 32GB              huge_pages = on
effective_cache_size = 96GB        work_mem = 256MB
maintenance_work_mem = 4GB         max_connections = 300
wal_level = minimal                max_wal_senders = 0
max_wal_size = 128GB               checkpoint_timeout = 30min
max_worker_processes = 32          max_parallel_workers = 16
max_parallel_workers_per_gather = 8
max_parallel_maintenance_workers = 8
effective_io_concurrency = 64      random_page_cost = 1.1
jit = off                          track_io_timing = on
autovacuum = off                   track_commit_timestamp = on
shared_preload_libraries = 'pg_prewarm'
pg_prewarm.autoprewarm = off
```

* `autovacuum = off` keeps the tables in the state the method puts them in.
  It also means that **nobody repairs the visibility map for you** (section 5).
* `track_commit_timestamp = on` is required by ACE.
* `wal_level = minimal` speeds up loading. It is only acceptable on isolated
  benchmark nodes; a trial that involves replication needs `logical`.
* Network levels, if they are a factor: shape the outgoing traffic of each node
  with `tc htb` (for example 5 Gbit and 1 Gbit) and check every level with
  `iperf3` node → client before the series. Native in-zone bandwidth was about
  31 Gbit/s.

## 3. Data

There are two families. Both have the shapes narrow, wide and toast and exactly
10 differences per table on n2, with the ground truth in table `gt (tbl, id, cat)`
on n2.

### 3.1 Family A: single `bigint` key, deterministic values

Every value is a function of the key (`hashint8extended`, `md5`). Each node
builds its tables independently, and the contents match on any
little-endian PostgreSQL 11+ instance.

| table | columns | rows | heap | TOAST |
|---|---|---|---|---|
| narrow | `id bigint` PK, 3 numeric, `int4`, `timestamptz` | 100M | 8 GB | — |
| wide | PK + 24 numeric, 8 text (one with NULLs), 4 int8, 2 timestamptz, 2 float8; row ≤ 560 B | 100M | 50 GB | — |
| toast | PK + 4 numeric + `payload` 2–4 KB, `STORAGE EXTERNAL` | 100M | 10 GB | 319 GB |

About 420 GB of disk per node, plus WAL. Loading takes about an hour per node
(16 vCPU, 4 × NVMe). Differences on n2 (`sql/a/diffs.sql`):

| table | change | keys |
|---|---|---|
| narrow | last digit of `n2` | 7M, 41M, 89M |
| narrow | `n1` + 0.01 | 23M, 67M |
| narrow | deleted | 13M, 52M, 97M |
| narrow | added | 100,000,001; 100,000,002 |
| wide | 12th decimal place of `u3` | 11M, 61M |
| wide | `t1`: NULL → `''` | 30,999,995; 82,999,995 |
| wide | `t2` + trailing space | 19M, 73M |
| wide | `f1`: last bit of float8 | 29M, 47M |
| wide | deleted / added | 55M / 100,000,001 |
| toast | character 1000 of `payload` → `X` | 9M, 37M, 79M |
| toast | last digit of `p1` | 21M, 58M, 93M |
| toast | deleted / added | 33M, 71M / 100,000,001; 100,000,002 |

These are chosen to catch weak hashing: NULL → `''`, a trailing space and one
float8 ULP are exactly what some tools miss.

Optional (`sql/a/diffs-density.sql`): many differences in one table, either
scattered over the key range or as one contiguous chunk. A block-hashing tool
slows down with the number of *blocks* that mismatch, not with the number of
rows. In an earlier ACE run, 0.0075% scattered differences took the time
from 25.5 to 205.8 s, while 5% in one chunk took it only to 115.9 s.

### 3.2 Family B: composite keys, random values

The base data comes from `random()`, so it is generated once on n1 and copied
to n2 byte for byte. Each node then builds the key variants from the same base
`ORDER BY id`, so the physical order is identical too.

| shape | columns besides the key | logical row | rows (trial 3 / trial 5) |
|---|---|---|---|
| narrow | `v bigint` | 88 B | 30M / 100M |
| wide | `v bigint`, `pad text` (164 chars) | 256 B, never TOASTed | 10M / 30M |
| toast | `v bigint`, `payload text` (2,912 chars, `STORAGE EXTERNAL`) | 3,004 B, 2 chunks per row | 1M / 3M |

| variant | primary key | what it tests |
|---|---|---|
| `_rk` | `(r numeric, h text, id numeric)` | first key column is random: key order ≠ heap order |
| `_sk` | `(id numeric, r numeric, h text)` | composite key that follows the heap |
| `_id` | `(id bigserial)` | the same rows with a single integer key |

`r = random()::numeric`, `h = md5(random()::text)`, `id` = 1…N. At the trial 5
sizes, narrow is 8.9 GB heap + 7.3 GB PK, wide 7.6 + 2.2 GB, toast 0.3 GB heap +
8.8 GB TOAST. Differences on n2 (`sql/b/diffs.sql`), with the same ids in every
variant of a shape:

| change | id | narrow | wide, toast |
|---|---|---|---|
| `v = v + 1` | N·0.10, N·0.35 | also N·0.60, N·0.85 | ✓ |
| one character of `pad` / `payload` → `X` | N·0.60, N·0.85 | | ✓ |
| deleted | N·0.20, N·0.50, N·0.80 | ✓ | ✓ |
| added (new random `r`, `h`, `v`) | N+1 … N+3 | ✓ | ✓ |

## 4. Building the data

`psql` below means `psql -X -q -v ON_ERROR_STOP=1` with the usual `PG*`
variables pointing at the node. The database must exist and use UTF8.

### 4.1 Family A (on each node independently)

```sh
psql -f sql/a/schema.sql
ROWS=100000000 JOBS=16; step=$(( (ROWS + JOBS - 1) / JOBS ))
for t in narrow wide toast; do
  for ((i = 0; i < JOBS; i++)); do
    lo=$(( i*step + 1 )); hi=$(( (i+1)*step )); (( hi > ROWS )) && hi=$ROWS
    psql -v lo=$lo -v hi=$hi -f sql/a/load-$t.sql &
  done; wait
done
psql -f sql/a/pk.sql
psql -f sql/a/diffs.sql                       # n2 only
psql -v tbl=wide -v mode=scatter -v frac=0.0001 -f sql/a/diffs-density.sql   # n2, optional
psql -f sql/common/finish.sql                 # only after ALL of the above has finished
psql -f sql/common/vm-check.sql
psql -f sql/common/layout.sql
psql -f sql/a/spot-check.sql                  # all 18 lines OK, on both nodes
psql -f sql/a/fingerprint.sql                 # optional, reads everything
```

* `JOBS=16` interleaves 16 key ranges in the heap (`correlation(id)` ≈ 0.06,
  as in the main trial); `JOBS=1` gives a heap ordered by key. The contents
  are the same, the physical layout is not (see 5.1).
* `spot-check.sql` compares the md5 of 18 rows with values recorded on
  PostgreSQL 18.6. Run it before `diffs-density.sql`: a scattered run can
  change one of its ids.
* For a trial run, use a smaller `ROWS`. `diffs.sql` assumes 100M rows,
  so on a small copy only the added rows show up as differences.

### 4.2 Family B

```sh
# n1: generate
psql -f sql/b/base-schema.sql
for s in narrow:100000000 wide:30000000 toast:3000000; do
  sh=${s%%:*}; n=${s##*:}; step=$(( (n + 15) / 16 ))
  for ((i = 0; i < 16; i++)); do
    lo=$(( i*step + 1 )); hi=$(( (i+1)*step )); (( hi > n )) && hi=$n
    psql -v lo=$lo -v hi=$hi -f sql/b/gen-$sh.sql &
  done; wait
done

# n2: copy the base tables from n1, byte for byte
psql -f sql/b/base-schema.sql
for t in base_narrow base_wide base_toast; do
  psql -h n1 -c "\copy $t TO STDOUT (FORMAT binary)" | psql -c "\copy $t FROM STDIN (FORMAT binary)" &
done; wait

# n1 and n2: the output of base-sum.sql must be identical
psql -f sql/b/base-sum.sql

# n1 and n2: build the variants (pairs can run in parallel)
for sh in narrow wide toast; do for v in rk sk; do
  psql -v shape=$sh -v variant=$v -f sql/b/build.sql &
done; done; wait

# n2 only, while the base tables still exist
psql -v narrow=100000000 -v wide=30000000 -v toast=3000000 -v variants='rk sk' -f sql/b/diffs.sql

# n1 and n2
psql -f sql/b/drop-base.sql
psql -f sql/common/finish.sql
psql -f sql/b/assert.sql
psql -f sql/common/vm-check.sql
psql -f sql/common/layout.sql
```

## 5. Physical state of the tables: layout and visibility map

The same rows can be stored in ways that make the same tool several times
slower. Two properties matter, and both must be fixed and recorded per run.

### 5.1 Heap order versus key order

Tools that read in primary key order (pgcmp, ACE) visit the heap in key order.
If the key does not follow the heap, every step is a random page access.
Sequential tools (pg_comparator, pgCompare) do not care.

* Family A with `JOBS=16`: `correlation(id)` ≈ 0.06. On cold toast, pgcmp and
  ACE read 4–7 times more from disk than the table holds; with a 4 MB md
  readahead most of each read is wasted.
* Family B `_rk`: the first key column is random. On a hot cache, pgcmp is
  1.1–1.7 times slower and ACE 1.1–1.6 times; on a cold cache 2.1–3.6 times.

`layout.sql` prints `pg_stats.correlation` for every key column.

### 5.2 Visibility map (new)

**What we found.** In the pgcmp slicer experiment (PostgreSQL 18, 10M rows,
both clusters on one laptop), the slicer makes one ordered pass over the
primary key and keeps every N-th key. The plan was an Index Only Scan in all
cases, yet the pass took from 0.26 s to 3.7 s:

| table | visibility map | heap order vs key | slicer pass |
|---|---|---|---|
| `t1` | full (after VACUUM) | same | 0.26 s |
| `t1n` | empty (never vacuumed) | same | 0.6–0.76 s |
| `t2`, key `(org, md5)` | 45% (60,339 of 133,334 pages) | random | 3.6–3.7 s |

```
Index Only Scan using t2_pkey on t2 (actual rows=10000000)
  Heap Fetches: 5474625
  Buffers: shared hit=13160519
```

An Index Only Scan skips the heap only for pages marked all-visible in the
visibility map. For every other page it fetches the heap tuple to check
visibility. The cost is the product of two factors: how much of the map is
unset and how random the heap access is. `t1n` has more heap fetches than `t2`,
but they go to consecutive pages, so they are cheap. `t2` combines a half-empty
map with a random key and is 14 times slower than `t1`.

The map also changes plans. The planner costs an Index Only Scan with
`relallvisible / relpages`. In the small-scale test of these scripts, `wide_rk`
with a full map got an Index Only Scan with 0 heap fetches (15 ms). After
`vm-degrade.sql` with `every=1`, the same query switched to
Seq Scan + external Sort (297 ms). So two nodes with identical rows but a
different map can run different plans for the same tool query.

**What it affects.** Every phase that reads only the key: slicing the table
into ranges (pgcmp slicer, the ACE slicer from #174), min/max key probes,
key-only counts. Hashing or fetching rows reads the heap anyway, so it does
not depend on the map. A tool whose slicing is a large part of the run time
(small tables, many workers, slicing on the critical path) is affected most.

**Why a map can stay incomplete after VACUUM.** Two mechanisms, one confirmed
and one suspected:

1. *Index-vacuum bypass (confirmed).* Since PostgreSQL 14, VACUUM skips index
   vacuuming when fewer than 2% of the heap pages have dead items (and there
   are few of them overall). The dead
   line pointers stay in the heap, and those pages are **not** marked
   all-visible. `diffs.sql` creates exactly this situation: a few deletes and
   non-HOT updates on a large table. In the small-scale test, plain
   `VACUUM (FREEZE)` reported `index scan bypassed: 7 pages from table (0.21%
   of total) have 7 dead item identifiers` and left those 7 pages out of the
   map. At 100M rows, it is a handful of pages, which is harmless for speed,
   but a map coverage check would then not be exact. `finish.sql` uses
   `INDEX_CLEANUP ON`, which forces the second pass, and coverage is 100%.
2. *A snapshot older than the load (suspected for `t2`).* VACUUM marks a page
   all-visible only if every tuple on it is visible to all running
   transactions. Anything that holds the xmin horizon back — a parallel load of
   another table still running, an idle `psql` inside `BEGIN`, a prepared
   transaction, a replication slot, `hot_standby_feedback` — leaves the
   freshly loaded pages out of the map. With `autovacuum = off`, they stay out.
   Why `t2` ended up at 45% was not investigated, so this is a hypothesis,
   though the most likely one: the bypass above cannot explain it, because it
   only applies below 2% of pages.

**Rules.**

* Run `finish.sql` only after every load, build and diff session has finished.
  It lists the holders of the xmin horizon and refuses to vacuum if there are
  any.
* After it, `vm-check.sql` on both nodes must pass (threshold 0.99 by
  default; after `finish.sql` it is 1.0000). Install `pg_visibility` to get
  the exact bit counts in addition to `pg_class.relallvisible`.
* Re-run `vm-check.sql` before every series and store its output with the
  results. A read-only table keeps its map, but anything that writes clears bits:
  a tool's repair mode, re-applied differences, `diffs-density.sql`. After any
  write, run `finish.sql` again.
* Do not use "load, then ANALYZE only" as a quick way to get an empty map: it
  also leaves hint bits unset, so the first tool run writes every page (and,
  with data checksums, which are on by default in PostgreSQL 18, WAL-logs
  them). That run then measures hint-bit setting, not comparison.

**The map as a factor.** Production tables often have a partly unset map. To
measure a tool on such a table without changing anything else, use
`vm-degrade.sql` after `finish.sql`:

```sh
psql -v tbl=narrow_rk -v every=2 -f sql/common/vm-degrade.sql   # ~45-50% all-visible
psql -v tbl=narrow_rk -v every=1 -f sql/common/vm-degrade.sql   # ~0%
psql -v min_vm=0 -f sql/common/vm-check.sql                     # report only
psql -v tbl=narrow_rk -f sql/common/keyscan-probe.sql           # Heap Fetches, plan
```

It does a no-op `UPDATE … SET id = id` of the first tuple of every N-th page
and then `ANALYZE`. The contents stay the same (checked with an md5 of the
whole table before and after), hint bits stay set, and the pages lose their
all-visible bit. On a 200k-row narrow table, `every=2` gave 45.7% coverage and
108k heap fetches per pass, against 0 before. The side effects: about
`pages/every` rows move to other pages, and the PK gets as many extra entries.
Record which side was degraded: both (symmetric) or only one.

A useful matrix for slicing-heavy tools is {full map, `every=2`, `every=1`} ×
{`_sk`, `_rk`} on both nodes.

## 6. Cache regimes

| regime | before each … | how |
|---|---|---|
| hot | series on a table | `prewarm.sql` on both nodes: heap and PK into the page cache (`'read'`), then into shared_buffers (`'buffer'`) |
| cold | run | restart PostgreSQL and `echo 3 > /proc/sys/vm/drop_caches` on both nodes |
| constrained shared_buffers | run | `shared_buffers` far below the heap (for example 16 MB for a 1 GB heap), restart, then `prewarm.sql -v mode=read` (page cache only) |

* "Hot" means "in the node's RAM", not "in shared_buffers". Family A wide with
  its PK (52 GB) does not fit in 32 GB of shared_buffers. The rest comes from the
  page cache: no disk reads, but each page costs a system call and an 8 KB copy.
* Family A toast (329 GB) does not fit in RAM at all and is always run cold.
* Check that a hot run really read nothing from disk (md0 read delta = 0).

## 7. Run protocol

1. Before a series on a table, on both nodes: `vm-check.sql`, `layout.sql`,
   then the cache regime (section 6).
2. Each tool, each configuration: 3 runs, take the median; runs longer than
   15 minutes once. Alternate the order of the tools between repetitions.
3. Record the metrics from section 1, plus tool version or commit, its
   parameters and the network level.
4. Score each run against `gt` on n2 (and `gt_density` if used): found,
   missed, false positives. Every miss must be explained by category.
5. Keep raw logs next to the summary CSV. One line per run:
   `table, tool, config, rep, wall, client_cpu, rss, node_cpu_n1, node_cpu_n2,
   rx_bytes, disk_rd_n1, disk_rd_n2, heap_hit_n1, heap_read_n1, heap_hit_n2,
   heap_read_n2, found, fp, vm_frac_n1, vm_frac_n2, cache, net`.

Tool notes from previous trials:

* **ACE.** The number of workers is `round(client NumCPU × c)` for both nodes
  together: `-c 1.0` on a 32-vCPU client ≈ 16 queries per node, which is
  the same as pgcmp `-j16`. Releases up to 2.1.1 and the main branch of mid-October
  slice blocks with `TABLESAMPLE SYSTEM`. On toast the blocks became 10–20
  times larger than `-b` and failed on the 1 GB limit (2.1.1) or on the 60 s
  block hash timeout (main). Use `-b 10000` on toast or a build with the slicer.
  Hash v3 (2.1.1) misses NULL → `''`; hash v4 (per-row sha256) finds it.
* **pg_comparator** uses one core per side (`--threads` is disabled for
  PostgreSQL). To parallelise, run 16 processes with `--where` over ranges of
  the first key column: 8.6–10.6 times faster with no code changes.
* **pgCompare**: `loader-threads = 0`, `observer-throttle = false`,
  `database-sort = false`. With `loader-threads = 1` the observer matched only
  14–22% of rows on the fly, and the tool was 3.4–6.6 times slower.
  The repository: PostgreSQL with `fsync = off`, `shared_buffers = 32GB`.
* **pgcmp**: `-j 16` and `-j 32`; `-rows N` sets the hash block size by rows.
  Its slicing pass is a key-only scan, so it is the first to suffer from an
  incomplete visibility map.

## 8. Known pitfalls

* **Incomplete visibility map.** Section 5.2. It is easy to get wrong and hard to
  notice, because the plan still says "Index Only Scan".
* **Different data on the nodes.** Family B must be copied, never generated
  twice. Check `base-sum.sql` on both nodes before building the variants.
* **Platform.** Family A relies on PostgreSQL hash functions, which differ on
  big-endian platforms. `spot-check.sql` catches it.
* **Text output settings.** `spot-check.sql` and `fingerprint.sql` set
  `TimeZone`, `DateStyle` and `extra_float_digits`. Tools that compare text
  rendering are sensitive to these too: keep them identical on both nodes.
* **Load parallelism changes the layout.** Keep `JOBS` fixed across the
  trials you want to compare, and record `layout.sql`.
* **Leftover sessions.** A forgotten `psql` in a transaction on a node not only
  spoils the map (5.2) but also keeps dead tuples alive during the run.
* **`fingerprint.sql` reads everything** (about 380 GB in family A). Do not run
  it between timed runs: it evicts the page cache.

## 9. Files

| file | where | what |
|---|---|---|
| `sql/a/schema.sql` | both | tables narrow, wide, toast, no keys |
| `sql/a/load-{narrow,wide,toast}.sql` | both | one key range `:lo..:hi` |
| `sql/a/pk.sql` | both | primary keys |
| `sql/a/diffs.sql` | n2 | 30 differences, table `gt` |
| `sql/a/diffs-density.sql` | n2, optional | scattered or contiguous mass differences, table `gt_density` |
| `sql/a/spot-check.sql` | both | md5 of 18 rows against recorded values |
| `sql/a/fingerprint.sql` | both | full-table fingerprint; equal output = equal tables |
| `sql/b/base-schema.sql` | both | unlogged base tables |
| `sql/b/gen-{narrow,wide,toast}.sql` | n1 | one key range of the random base data |
| `sql/b/base-sum.sql` | both | checksum of the base tables |
| `sql/b/build.sql` | both | one variant (`-v shape -v variant`) from the base |
| `sql/b/diffs.sql` | n2 | 10 differences per table, table `gt` |
| `sql/b/drop-base.sql` | both | drop the base tables |
| `sql/b/assert.sql` | both | sizes, row widths, TOAST asserts |
| `sql/common/finish.sql` | both | xmin-holder check, `VACUUM (FREEZE, ANALYZE, INDEX_CLEANUP ON)`, `CHECKPOINT` |
| `sql/common/vm-check.sql` | both | visibility map coverage with an assertion |
| `sql/common/layout.sql` | both | sizes and key/heap correlation |
| `sql/common/keyscan-probe.sql` | both | slicer-like key-only pass under `EXPLAIN ANALYZE` |
| `sql/common/vm-degrade.sql` | either | optional: partly unset map, same contents |
| `sql/common/prewarm.sql` | both | hot-cache regime |

All scripts were run end to end on a small scale (family A with 200k rows,
family B with 300k / 100k / 10k rows) on PostgreSQL 18.6. That covers both
negative checks: `finish.sql` refusing to vacuum while another session held a
snapshot, and `vm-check.sql` failing on a degraded table.
