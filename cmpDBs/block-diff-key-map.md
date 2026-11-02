# Compare a mismatched block through a key map


## 1. Today

table-diff and mtree diff find the differences in two steps. First, they compare the hash of every block on two instances. Second, for every block whose hashes are not equal, they find the rows that differ.

**table-diff.** A mismatched block goes to `recursiveDiff`. It splits the block into two halves (`generateSubRanges`, with `ntile` on one instance), hashes each half on both instances again, and repeats this for every half that does not match. When a range has fewer rows than `compare_unit_size` (default 10000), `compareBlocks` reads all rows of the range from both instances, with all columns and `ORDER BY` the primary key. `CompareRowSets` puts the rows of each side into a Go map by a string form of the key and compares the values in Go.

The hash query of a block already returns the number of rows in the block on this instance (`hashRange` returns it), but the result of the first hash pass keeps only the hash.

**mtree diff.** For a work item (a list of mismatched leaf ranges), `processWorkItem` reads the key and the row hash (`RowHashExpr`) of every row in the ranges from both instances, with `ORDER BY` the key, into two Go maps. The map key is built in Go from typed key values (`pkeyIdentity`), so only a fixed list of key types works. Then it reads the full rows for the mismatched keys from both instances, 2000 keys per query, with `key IN (...)` or `(k1, k2) IN ((...), ...)`.

repset-diff and schema-diff run table-diff for every table, so they work in the same way.

## 2. Problems

1. **Repeated scans.** In table-diff, one mismatched block of B rows needs about log2(B / compare_unit_size) levels of new hash queries on both instances, plus one `ntile` query per split. With several differences spread over the block, many halves are scanned again.
2. **Full rows travel for equal rows.** At the last level, table-diff reads every row of the range from both instances, with all columns, even when only one row differs. For wide rows this is most of the network traffic of a diff.
3. **Sorting on the server.** Both table-diff and mtree ask for `ORDER BY` the key, but the client does not need any order: it compares rows through a map.
4. **Two maps where one is enough.** Both table-diff and mtree keep the rows (or row hashes) of both instances in memory at the same time.
5. **Key identity in Go.** The map key is built from Go values. Every key type needs its own Go code, and a type that Go renders in a different way than Postgres gives wrong results. mtree refuses key types that are not on its list.

## 3. Goal

For a block whose hashes do not match on two instances:

- Each instance scans the block once.
- Only the key and a short row hash travel for the rows that are equal. Full rows travel only for the rows that differ.
- The client keeps in memory the keys and hashes of one side only, the smaller one.
- The client compares only bytes for equality. It never orders key values and never converts them to Go types.
- Full rows are read through the primary key index, not through a sequential scan.

The same method is used by table-diff (and so by repset-diff and schema-diff) and by mtree diff.

Out of scope:

- One snapshot for all queries of a run. Like today, the block hash, the key queries and the row reads run in different transactions, so a row that changes during the run can be reported as a difference.
- table-rerun. It reads rows by keys from a diff report, which is a different input (typed values from JSON). It can use the new row read (section 4.6) later.
- The first hash pass and the way the table is cut into blocks.

## 4. Solution

### 4.1 Terms

- **Block**: the part of the table that both instances hashed, with the same WHERE clause on both instances. In table-diff it is a key range plus the optional filter. In mtree diff it is the WHERE clause that `processWorkItem` builds today from the leaf ranges and the commit timestamp limit.
- **Build side**: the instance whose keys and row hashes go into the map.
- **Probe side**: the other instance. Its keys and row hashes are read as a stream and checked against the map.
- **Key text**: the text form of each primary key column, as the server sends it in the text result format.
- **Key ID**: the bytes that identify a row on the client (section 4.3).

### 4.2 Key query

The same query runs on both instances:

```sql
SELECT <key expr 1>, ..., <key expr k>,
       substring(<row hash> FROM 1 FOR 16) AS row_hash
FROM <schema>.<table> AS _tbl_
WHERE <block clause>
```

- `<key expr i>` is the key column. For a numeric column it is `trim_scale(<column>)`, so that `1.50` and `1.5` give the same key text, in the same way as the row hash does.
- `<row hash>` is `queries.RowHashExpr` over all columns of the table, the same expression that the block hash uses. The key columns are part of it. This is enough: when the keys are equal, the hash of the full row says if the rest of the row is equal. There is no separate hash for "the columns that are not the key".
- The first 16 bytes of sha256 are enough to find a changed row. The chance that two different rows give the same 128 bits is very small.
- There is no `ORDER BY`.
- The key columns are read in the text result format (pgx `QueryResultFormats`), and the row hash in the binary format. ACE connections use `client_encoding = UTF8` and pin `DateStyle`, `IntervalStyle`, `TimeZone`, `extra_float_digits` and `bytea_output`, so the same key value gives the same key text on every instance, also when the databases use different encodings.

### 4.3 Key ID

The key ID is built on the client from the key texts of one row: for each key column, the length of the text as an unsigned varint, then the bytes of the text. This form has no ambiguity (a comma or a quote inside a value does not matter), and the client can split it back into the key texts to read the row later (section 4.6).

A primary key column cannot be NULL. If a key query returns NULL in a key column, the comparison stops with an error.

The map is `map[string][16]byte`: the key ID to the row hash. The map holds the key texts, so a separate hash of the key is not needed.

### 4.4 Choosing the build side

The first hash pass keeps the row count of every block on every instance (`HashResult` gets a field `rows`). For a mismatched block the instance with fewer rows is the build side. If the counts are equal, the first instance of the pair is the build side.

mtree diff has no row counts per leaf, so the first instance of the pair is the build side.

The counts come from another transaction and can be a little out of date. This changes only the choice of side, not the result.

If the build side has 0 rows, the build step is skipped: the map is empty, and every probe row is a row of the probe side only.

### 4.5 Build and probe

1. **Build.** Run the key query on the build side and put every row into the map.
2. **Probe.** Run the key query on the probe side and read it row by row. For each row:
   - the key ID is not in the map: the row exists on the probe side only. Add the key ID to the list of differing keys.
   - the key ID is in the map, the hashes are not equal: the row is changed. Add the key ID to the list.
   - the key ID is in the map, the hashes are equal: delete the entry from the map.
3. **After the probe.** The entries left in the map are the rows of the build side only. Add their key IDs to the list.

Deleting the equal rows makes the map smaller during the probe.

The probe stops early when the list holds as many keys as the pair can still report (`max_diff_rows`). In this case the entries left in the map are not added, because some of them can still match rows that the probe did not read. The pair is marked as stopped by the limit, as today.

### 4.6 Reading the differing rows by key

The full rows of the differing keys are read from **both** instances, in batches of up to 2000 keys. Each batch is one query. The key texts go as one `text[]` parameter for each key column:

```sql
SELECT k.pos, r.*
FROM unnest($1::text[], ..., $k::text[]) WITH ORDINALITY AS k(c1, ..., ck, pos)
CROSS JOIN LATERAL (
    SELECT substring(<row hash> FROM 1 FOR 16) AS row_hash,
           pg_xact_commit_timestamp(_tbl_.xmin) AS commit_ts,
           to_json(pg_xact_commit_timestamp_origin(_tbl_.xmin))->>'roident' AS node_origin,
           <select list of all columns, with SelectColExpr>
    FROM <schema>.<table> AS _tbl_
    WHERE _tbl_.<key 1> = k.c1::<type 1> AND ... AND _tbl_.<key k> = k.ck::<type k>
    OFFSET 0
) AS r
```

- `<type i>` is the type of the key column on this instance (`format_type`), as ACE already reads it per instance.
- The cast from text gives a value equal to the stored one: the key text came from the output function of the same type, and a numeric key cast from `1.5` is equal to the stored `1.50`.
- `OFFSET 0` keeps the planner from turning the LATERAL subquery into a join. So the plan is always a nested loop: for each key, one parameterized lookup on the table. For a key equality this lookup is an index scan on the primary key index. A hash join with a sequential scan of the table is not possible with this form, for any number of keys.
- For a partitioned table the lookup is an Append over the partitions. The primary key of a partitioned table contains the partition key, so the planner prunes the partitions at run time.
- `pos` tells which key of the batch the row belongs to, so the client does not need to read the key back from the row.
- The comparison of the key column with a text cast uses the collation of the column, so the primary key index can be used also for a column with a non-default collation.

Reading from both instances also covers the case when a row changed after the probe.

### 4.7 Final result

For every differing key, after the rows are read on both instances:

| Row found on | Row hashes | Result |
| --- | --- | --- |
| first instance only | — | row of the first instance only |
| second instance only | — | row of the second instance only |
| both | not equal | changed row |
| both | equal | no difference (the row changed during the run) |
| none | — | no difference (the row was deleted during the run) |

The result uses only the row hashes from the server. The Go comparison of values (`CompareRowSets`, `areRowsModified`) is not used here any more. The diff report keeps the same format: the rows, `commit_ts` and `node_origin`, as today.

### 4.8 Memory limit

The memory that the client uses for the keys of one block (the map plus the list of differing keys) is limited in megabytes by a new setting:

- `table_diff.key_map_max_memory_mb` for table-diff, repset-diff and schema-diff;
- `mtree.diff.key_map_max_memory_mb` for mtree diff.

The default is 512. 0 means no limit.

The limit is in bytes, not in rows, because the size of an entry depends on the key. A table with a long text key, or one row with a very long key value, can pass a row limit and still use much more memory than expected. A limit in bytes works the same way for every slicer: also for the cutter, where the number of rows in a block is known in advance.

**How memory is counted.** The comparator keeps a counter of bytes. Each entry adds `len(key ID) + 16 + entry overhead`, where the entry overhead is a fixed constant in the code for the cost of one Go map entry (string header, bucket share). The counter goes up when an entry is added to the map or to the list of differing keys, and goes down when an entry is deleted from the map. The counter is an estimate, not a measurement of the Go heap, but it grows with the real memory and does not depend on the garbage collector.

**When the check runs.**

1. Before the build. ACE estimates the memory of the build side as `rows × (average key size + 16 + entry overhead)`. `rows` is the row count from the first hash pass. The average key size is the sum of `avg_width` of the key columns from `pg_stats` on the build side; if there are no statistics, ACE skips this check. If the estimate is above the limit, the run stops before the block is read.
2. During the build and the probe. Every time the counter grows, ACE compares it with the limit. When it is above the limit, the query is cancelled and the run stops.

The error names the table, the block bounds, the two instances, the row counts, the memory counted at the stop and the setting.

With the default block sizes (table-diff 100,000 rows, mtree up to 1,000,000) and keys of normal size this limit is not reached. It can be reached with very large blocks from the sample slicer, with very long keys, or when one instance has almost no rows in a large block (then the list of differing keys holds all probe rows).

The limit does not cover the full rows that are read by key (section 4.6). They are read in batches of 2000 keys and go into the diff result, which is kept until the report is written and is limited by `max_diff_rows`, as today.

Several blocks can be compared at the same time (the number of comparison workers). The limit is per block, so the total memory can be this number times the limit. The documentation must say this.

### 4.9 Connections, errors and cancel

- The build query, the probe query and the row reads of one block run one after another. A comparison worker uses one connection to an instance at a time, as today, so the connection limits of the comparison phase do not change.
- The connection of the probe side stays busy while the probe reads its stream. The worker does no other network calls during the probe.
- An error in any query of a block records the error for the run, as today. Context cancel stops the probe stream and the row reads.

### 4.10 Key equality

The client compares key IDs as bytes. Two keys that the server holds as equal but prints in a different way are seen as two different rows: `-0` and `0` in a float column, `citext` values that differ only in case, values under a nondeterministic collation. Such a row is reported as "only on the first instance" plus "only on the second instance", not as a changed row. Logical replication copies values as they are, so these cases are not expected between replicas. Today's `CompareRowSets` has the same behaviour, so this is not a change.

## 5. Changes in the code

### 5.1 Shared code

A new package `internal/consistency/keydiff` with:

- the builder of the key query (section 4.2), which takes the block WHERE clause and its arguments from the caller;
- the key ID codec (section 4.3);
- the comparator: build, probe, the list of differing keys and the early stop (section 4.5);
- the builder and the runner of the row read by key (section 4.6);
- the final result (section 4.7).

The comparator does not know which command calls it. It takes a block description, two connections or pools, the column list and types, the limits, and returns the differing rows of both instances.

### 5.2 table-diff

- `HashResult` keeps the row count of the block.
- A mismatched block goes to the comparator directly, with the build side chosen by the row counts.
- `recursiveDiff`, `RecursiveDiffTask`, `generateSubRanges`, `generateSubRangesViaNtile`, `compareBlocks` and the range form of `fetchRows` are removed.
- repset-diff and schema-diff need no change other than the setting in section 6.

### 5.3 mtree diff

- `processWorkItem` uses the comparator with the WHERE clause it builds today. The key query has no `ORDER BY`.
- `readRowHashes`, `rowHashEntry`, `buildFetchRowsSQLSimple`, `buildFetchRowsSQLComposite` and the use of `pkeyIdentity` for row identity are removed. `comparePkeyValues` and the other code for leaf bounds stay.
- mtree diff no longer refuses a key type because Go cannot render it.

## 6. Settings and compatibility

- `compare_unit_size` (CLI `--compare-unit-size` / `-u`, the HTTP API field, the scheduler job argument and `table_diff.compare_unit_size` in the settings file) has no meaning any more. ACE still accepts it, ignores it and writes a warning once per run. It is removed from the documentation tables and from `ace.sample.yaml`, and the CHANGELOG says so in the Upgrading section.
- New settings `table_diff.key_map_max_memory_mb` and `mtree.diff.key_map_max_memory_mb` (section 4.8), in `ace.sample.yaml` and in `docs/configuration.md`. They are in the settings file only, without a CLI flag.
- The format of the diff report does not change.
- Documentation to update: `docs/design/table_diff.md`, `docs/design/merkle.md`, `docs/commands/diff/*.md`, `docs/api.md`, `docs/http-api.md`, `docs/openapi.yaml`, `docs/configuration.md`, `docs/performance.md`, `docs/best_practices.md`, `CHANGELOG.md`.

## 7. Tests

Unit tests:

- Key ID codec: values with commas, quotes, parentheses, empty strings, non-ASCII text; split back gives the same texts; NULL gives an error.
- Comparator with fake streams: each case of section 4.5, an empty build side, an empty probe side, all rows equal, all rows different, early stop by `max_diff_rows`; the memory counter goes up on add and down on delete; the memory limit before the build (from the estimate), during the build and during the probe (an empty build side and a probe side that is all differing keys).
- Final result: each line of the table in section 4.7.

Integration tests (two Spock nodes and native replication, as the current tests):

- One block with a changed row, a row on the first node only and a row on the second node only; simple and composite keys.
- Key types: integer, bigint, numeric (`1.50` on one node and `1.5` on the other is the same row), text with a non-default collation, uuid, timestamp with time zone, date, bytea, an enum.
- A partitioned table with differences in two partitions.
- table-diff with `--table-filter`.
- The build side is the instance with fewer rows (check with the debug log or a counter).
- Memory limit with `key_map_max_memory_mb` set to 1: a block with many rows fails before the build (estimate from `pg_stats`); a small block with a few very long text keys and no statistics fails during the build. Both give the expected message.
- The row read by key uses the primary key index: run `EXPLAIN` on the read query for a batch of 2000 keys on a table of 1,000,000 rows and check that the plan has no `Seq Scan` on the table; the same on a partitioned table.
- `--compare-unit-size` is accepted and gives the warning.
- mtree diff: the existing tests pass; a new test with a key type that mtree refused before.
- The existing table-diff, repset-diff and schema-diff tests pass without changes to the expected reports.

## 8. Benchmark

On the GCE stand (two nodes, one region), table of 10M rows, default block size, compare the current main with the new code:

1. One changed row in one block.
2. One changed row in each of 100 blocks.
3. 10% of the rows of one block changed.
4. One block that is missing on one node.

Measure: total time, time of the diff phase, bytes sent by each server, server CPU time, number of queries per mismatched block. Expected: the diff phase is faster in cases 1–3, and the traffic of the diff phase falls by the share of the row width that is not the key and the 16-byte hash.

## 9. Pull requests

1. The shared package (section 5.1) with unit tests and the `EXPLAIN` integration test of the row read.
2. table-diff on the comparator; `recursiveDiff` removed; `compare_unit_size` deprecated; `table_diff.key_map_max_memory_mb`; documentation.
3. mtree diff on the comparator; `mtree.diff.key_map_max_memory_mb`; documentation.
