# ACE: node settings that change the comparison result

ACE computes the row hash from text: `sha256(convert_to(ROW(...)::text, 'UTF8'))`, the first 8 bytes, with numeric columns wrapped in `trim_scale()` (`RowHashExpr`, `db/queries/queries.go`). So anything that changes the text output of a value, or the order of keys, can produce a false mismatch.

The values in group 1 are the same as `deparseSettings` in `internal/consistency/schema/collect.go`. There must be one list, shared by schema-diff and by the data paths (table-diff, mtree, CDC).

## Group 1. Session GUCs: pin them in every ACE connection

Set them in the startup packet (`RuntimeParams` in `applyRuntimeParams`, `internal/infra/db/auth.go`). This includes the CDC replication connection: pgoutput converts values to text inside the walsender, with the GUCs of that session.

At the moment the data paths do **not** pin these settings: `applyRuntimeParams` sets only `statement_timeout`, the keepalive options and `application_name`.

### `TimeZone = 'UTC'`

- **Affects:** the output of `timestamptz`. It does not affect `timestamp`, `date` or `timetz` (a `timetz` value stores its own offset).
- **Why UTC:** UTC has no daylight saving rules. For a named zone (`Europe/Berlin`) the output depends on the tzdata version on the node. With `--with-system-tzdata` and different OS packages, the same `TimeZone` can still print different text for dates whose rules were changed.

### `DateStyle = 'ISO, YMD'`

- **Affects:** the output of `date`, `timestamp`, `timestamptz` (ISO / SQL / Postgres / German formats). The second part (`YMD` / `DMY` / `MDY`) does not change ISO output, but it controls how ambiguous input is parsed.
- **Why ISO:** it is the only unambiguous format, and pg_dump uses it too. For repair: values sent back as text are in ISO, so they are parsed the same way with any field order. `YMD` keeps the value equal to collect.go.

### `IntervalStyle = 'postgres'`

- **Affects:** the output of `interval` (`1 day 02:00:00`, `P1DT2H`, `+1 +2:00:00`, and so on).
- **Why postgres:** it is the default, and pg_dump sets the same value. Input in this format is accepted with any `IntervalStyle`, so repair is safe. All four styles are lossless; the choice simply follows pg_dump.

### `bytea_output = 'hex'`

- **Affects:** the output of `bytea` (`\x0102` or the escape format).
- **Why hex:** it is the default since 9.0. It is faster and has a fixed size (2 characters per byte). The escape format can use up to 4 characters per byte for binary data. Input accepts both formats.

### `extra_float_digits = 3`

- **Affects:** the output of `float4` / `float8`.
- **Why 3:** on PG12+ any value above 0 gives the shortest exact (round-trip) form, and 0 or below gives rounded output (15 / 6 significant digits). With rounding, different values can print the same, and the mismatch is missed. 3 is the maximum, it gives exact output on all versions, and pg_dump uses it. A false mismatch appears when one node has 0 in `postgresql.conf`.

### `lc_monetary = 'C'`

- **Affects:** the output of `money`: the currency symbol, the separators and **the number of fraction digits**. `money` stores an integer in the smallest units, and the output scale comes from the locale: the same stored `100` prints as `$1.00` under `C` and as `¥100` under `ja_JP`.
- **Why C:** this locale exists on every system. Another locale may fail to set if it is not installed on the node (the connection fails). The output under `C` is fixed: `$1,000.00`.

### `search_path = pg_catalog`

- **Affects:** the output of the reg* types: `regclass`, `regtype`, `regproc`, `regprocedure`, `regoper`, `regoperator`, `regconfig`, `regdictionary`, `regcollation`. The name gets a schema prefix only when the object is not visible through `search_path`, so a `regclass` column gives `t` on one node and `public.t` on another. It does not affect `regnamespace` and `regrole`.
- **Why pg_catalog:** no user object is visible without a schema, so both nodes print every name with its schema. An empty `search_path` gives the same result, but `pg_catalog` is more explicit.
- **Risk:** every SQL query in ACE must qualify user tables and its own helper functions with a schema (see the comment about `bytea_xor` in `merkle.go`). Check this before enabling.

### `quote_all_identifiers = off`

- **Affects:** quoting in the output of reg* types and in `format_type` / `pg_get_*` (`"t"` or `t`).
- **Why off:** it is the default. The value itself does not matter; it only has to be the same on all nodes. Pin it in case one node enables it in `postgresql.conf`. collect.go does not have it — add it there too.

## Group 1a. No effect on the hash, but needed for repair

### `standard_conforming_strings = on`

- **Affects:** parsing of string literals in the SQL that ACE builds. With `off`, a backslash in `'...'` becomes an escape character, and repair writes a different value. It does not affect output.
- **Why on:** it is the default since 9.1, and a literal means exactly what it contains. The best option is to send values as parameters (`$1`); then this setting does not matter.

### `xmloption = content`

- **Affects:** parsing of `xml` input. With `document`, inserting a fragment fails. It does not affect output.
- **Why content:** it is the default; it accepts both fragments and documents (since PG16, also documents with DOCTYPE).

### `client_encoding = UTF8`

pgx sets it itself. This is the encoding in which Go receives values for the row-by-row comparison.

## Group 2. Cannot be pinned in a session: snapshot and check before the comparison

`mtree build` stores a snapshot next to the range bounds. The diff compares the snapshots before it reads any data. By default it stops; with `--ignore-node-settings-mismatch` it continues and puts a warning at the top of the report.

### PostgreSQL major version (`server_version_num / 10000`)

- **Affects:** the output of some types across versions (for example, float in PG12) and the set of available functions (`trim_scale` exists since PG13).
- **Why only the major version:** project policy does not allow changes to output formats in minor releases. Comparing minor versions would cause false stops during a rolling upgrade.

### Collation of PK columns

For each PK column of a collatable type (including domains, arrays and composites over such types):

- provider (`libc` / `icu` / `builtin`), name, `collversion` and `pg_collation_actual_version()`; for the default collation, `datcollversion`;
- the deterministic flag.

- **Affects:** the order of keys, so the range bounds. A row can fall into different blocks on different nodes, and the blocks give a false mismatch. With a nondeterministic collation, key equality itself changes (`'A' = 'a'`). A PK of `int` / `uuid` / `timestamp` does not need this check.
- **Why with the version:** the same name `en_US.UTF-8` sorts differently on glibc 2.27 and 2.28. Only `collversion` shows the ICU or glibc version.

### Order of enum values in the PK

- **Affects:** the order of keys. Sorting uses `enumsortorder`, not the text. With different `ADD VALUE BEFORE/AFTER` history, the order differs between nodes.
- **What to store:** the list of labels in `enumsortorder` order.

### Non-default btree opclass on the PK index

- **Affects:** the order of keys, like a collation.
- **What to store:** the opclass name and the version of the extension that provides it.

### Versions of extensions whose types appear in table columns

- **What to store:** `pg_extension.extversion`; for PostGIS also `postgis_lib_version()`, because the library and the SQL part are upgraded separately.
- **Affects:** the output of these types, which can change between versions.

### `server_encoding`

- Information only, with one exception: **stop on `SQL_ASCII`**.
- **Why:** `convert_to(..., 'UTF8')` makes the encodings equal, so LATIN1 and UTF8 give the same hash. But there is no conversion from `SQL_ASCII`; the bytes pass as they are. LATIN1 bytes on such a node and the same characters in UTF8 on another node give different hashes.

## Group 3. Structural preconditions (schema-diff must pass)

These are not settings, but if they are broken, every row gets a false mismatch:

- **Attribute order of a composite type.** `record_out` prints attributes in the catalog order of its own node. Gaps in attnum do not matter; a different order does.
- **Column types.** `timestamp` and `timestamptz` print differently. `numeric(10,2)` and `numeric` compare correctly (`trim_scale`), but a domain over `numeric` does not (see `isNumericType`).
- **Enum labels.**

Run order: schema-diff first, then data-diff.

## Group 4. Not settings, but they look like false mismatches

- **Different snapshot time on each node:** transactions in progress and replication lag. Such mismatches disappear on the next run.
- **CDC slot lag:** the mtree tree shows an older state.
- **Stored generated columns** with functions declared `IMMUTABLE` that in fact depend on GUCs. Before PG18 they are computed on the subscriber, so the values really differ, but the cause is the configuration, not lost data.

## Settings that do not matter

- `lc_numeric`, `lc_time` — only `to_char`;
- `timezone_abbreviations` — input only; UTC output has no abbreviations;
- `lc_collate` / `lc_ctype` for non-PK columns — the hash uses the bytes of the text;
- `default_toast_compression`;
- the PostgreSQL minor version.
