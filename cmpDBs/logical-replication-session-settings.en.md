# Logical replication: how the subscriber aligns session settings with the publisher

This document describes built-in PostgreSQL logical replication (`CREATE SUBSCRIPTION`, the `pgoutput` plugin). The behaviour was checked against the source code of the master branch:

- `src/backend/replication/libpqwalreceiver/libpqwalreceiver.c` — `libpqrcv_connect()`;
- `src/backend/replication/logical/proto.c` — `logicalrep_write_tuple()`, `logicalrep_read_tuple()`;
- `src/backend/replication/logical/worker.c` — `slot_store_data()`;
- `src/backend/libpq/pqformat.c` — `pq_sendcountedtext()`, `pq_sendtext()`;
- `src/backend/utils/mb/mbutils.c` — `pg_server_to_any()`.

Older minor releases may not have all of the forced settings. For a specific version, check its own source code.

## 1. How a value travels from the publisher to the subscriber

1. **Publisher (walsender).** By default the column value is converted to text by the output function of its type (`OidOutputFunctionCall`). This function uses the GUCs of the walsender session. The text is then sent with `pq_sendcountedtext()`, which **converts it to the client encoding** (`client_encoding` of that session).
2. **Subscriber (apply worker).** The text is parsed by the input function of **the column type on the subscriber**, with **the column typmod on the subscriber** (`OidInputFunctionCall`). This function uses the GUCs of the apply worker session, that is, the subscriber settings.

So two independent sets of settings affect the result: the walsender session settings on output, and the subscriber settings on input. The subscriber controls only the first set. It does not change its own GUCs on purpose. From `libpqrcv_connect()`: "We don't want to modify the subscriber's GUC settings, since that might surprise user-defined code running in the subscriber, such as triggers".

The initial table synchronisation (tablesync, `COPY ... TO STDOUT`) uses the same kind of logical replication connection, so everything below applies to it as well.

## 2. What the subscriber sets for the walsender at connection time

For a logical connection, `libpqrcv_connect()` adds the following to the connection string:

| Parameter | Value | Purpose |
|---|---|---|
| `client_encoding` | the subscriber database encoding | "Tell the publisher to translate to our encoding": the publisher does the conversion |
| `datestyle` | `ISO` | unambiguous output of dates and times |
| `intervalstyle` | `postgres` | unambiguous output of `interval` |
| `extra_float_digits` | `3` | exact (round-trip) output of `float4`/`float8` |
| `search_path` | `''` (empty) | `ALWAYS_SECURE_SEARCH_PATH_SQL` runs right after the connection is made |

The code comment says: "Force assorted GUC parameters to settings that ensure that the publisher will output data values in a form that is unambiguous to the subscriber… This should match what pg_dump does".

`datestyle`, `intervalstyle` and `extra_float_digits` are passed through `options` (`-c ...`) and are added **after** any `options` that the user put in the subscription connection string. When the same `-c` appears twice, the last one wins, so the user cannot override these three settings. Other publisher GUCs can be set through `options`.

## 3. Encoding

The subscriber always asks the publisher to convert data to the subscriber encoding. What happens next depends on `pg_server_to_any()` on the publisher:

| Publisher | Subscriber | Result |
|---|---|---|
| X | X (same) | No conversion; bytes are sent as they are, without validation. |
| UTF8 | LATIN1, etc. | The publisher converts. If a character cannot be represented in the subscriber encoding (Cyrillic in LATIN1, emoji), the walsender fails with `character with byte sequence ... in encoding "UTF8" has no equivalent in encoding "LATIN1"`. |
| LATIN1, etc. | UTF8 | The publisher converts; conversion from a single-byte encoding to UTF8 always succeeds. |
| `SQL_ASCII` | X ≠ `SQL_ASCII` | No conversion (the source encoding is unknown), but the bytes are **validated** in the subscriber encoding. ASCII and bytes that are valid in X pass; other bytes cause `invalid byte sequence for encoding ...`. |
| any | `SQL_ASCII` | No conversion and no validation; the bytes are stored as they are. |

What a conversion error means in practice:

- the walsender fails, the apply worker reconnects and gets the same error on the same transaction again. Replication stops, the slot keeps WAL, and disk usage on the publisher grows;
- the situation does not resolve by itself. Manual action is needed: fix the data on the publisher or skip the transaction (`ALTER SUBSCRIPTION ... SKIP (lsn = ...)`).

There is no silent corruption caused by encoding. The one exception is a subscriber in `SQL_ASCII`, which accepts any bytes.

In binary mode, text types are sent through `textsend()` → `pq_sendtext()`, which does the same conversion. The behaviour is the same.

## 4. Session settings: what happens when they differ

### Forced by the subscriber — a difference has no effect

- **`DateStyle`.** The publisher always prints ISO. ISO input is parsed the same way with any subscriber `DateStyle`, including the `DMY`/`MDY` order.
- **`IntervalStyle`.** The publisher always prints the `postgres` style. Input in this format is accepted with any subscriber `IntervalStyle`.
- **`extra_float_digits`.** The publisher always prints the exact value, so nothing is lost.
- **`search_path`.** The publisher works with an empty `search_path`, so reg* values (`regclass`, `regtype`, `regproc`, etc.) are printed with the schema name (except objects in `pg_catalog`). The subscriber parses a qualified name the same way with any `search_path`. The name is stored, not the OID, so on the subscriber the value points to its own object with the same name. If no such object exists, the result is an error.

### Not forced, but a difference is safe

- **`TimeZone`.** `timestamptz` is printed with an offset (`2026-10-06 15:00:00+03`). The subscriber takes the offset into account and stores the same point in time. The text differs between nodes; the value is the same. `TimeZone` does not affect `timestamp`, `date` or `timetz`.
- **`bytea_output`.** `bytea` input accepts both `hex` and `escape`.
- **`lc_numeric`, `lc_time`.** They affect only `to_char`, not output/input functions.
- **`standard_conforming_strings`.** Values are sent separately from SQL; no literals are parsed.

### Not forced, and a difference is dangerous

- **`lc_monetary`.** `money` is printed with the walsender locale (currency symbol, separators, number of fraction digits) and parsed with the subscriber locale. Consequences:
  - different symbols or separators — a parse error, replication stops;
  - a different number of fraction digits — **silent distortion**: the value is stored with a different scale.

  What to do: use the same `lc_monetary` on both nodes, or use binary mode (`cash_send` sends an integer without the locale), or do not use `money`. You can set `lc_monetary` for the publisher through `options` in the subscription connection string, but it must match the subscriber `lc_monetary`.
- **`xmloption`.** `xml` output does not depend on it, but input on the subscriber does. If the subscriber has `xmloption = document`, an XML fragment (not a full document) causes an error and stops replication.

## 5. Node differences that are not session settings

- **Column types.** Columns are matched by name, and the value is parsed by the input function of the subscriber type. So different types are allowed as long as the text can be parsed (`int4 → int8`, `numeric → text`). If parsing fails, the result is an error and replication stops.
- **Column typmod.** The subscriber typmod is applied. `varchar(5)` with a longer string gives an error. `numeric(10,2)` and `timestamp(0)` **silently round** the value.
- **Enum labels.** The label text is sent. If the subscriber has no such label, the result is an error.
- **Extension versions.** The input function of the type on the subscriber must accept the output of the version on the publisher. If the format changed, the result is an error or a wrong value.
- **Major versions.** Replication between major versions is supported in both directions; the protocol version is agreed at start (`proto_version`). Text output of different versions is parsed by input functions.
- **Collation and its version.** The protocol does not send collations. The apply worker finds the row for UPDATE/DELETE through an index on the subscriber, with the subscriber comparison rules. If the glibc or ICU version changed without `REINDEX`, the index is in fact corrupted, and the row may not be found. In that case UPDATE/DELETE is **silently skipped**: before PG18 the message is written at `DEBUG1`; in PG18 it is an `update_missing` / `delete_missing` conflict at `LOG` level. As a result, the data on the nodes diverges.
- **Binary mode** (`WITH (binary = true)`). Send/recv functions are used, and session GUCs do not affect them. But the type on the subscriber must accept the binary format of the publisher type. Different types (`int4` → `int8`) or different type versions cause `incorrect binary data format`; there is no implicit cast.

## 6. Summary: what you must align by hand

The subscriber itself takes care of `DateStyle`, `IntervalStyle`, `extra_float_digits`, `search_path` and the encoding. The rest is the administrator's job:

1. **Encoding:** the subscriber encoding must be able to represent every character from the publisher. Otherwise replication stops.
2. **`lc_monetary`:** the same on both nodes, or binary mode, or no `money` columns.
3. **`xmloption`:** `content` on the subscriber (the default).
4. **Column types and typmods:** the same, otherwise errors or silent rounding are possible.
5. **Collations:** the same library versions, or `REINDEX` after a glibc/ICU upgrade; otherwise UPDATE/DELETE may be skipped.
6. **Enum labels and extension versions:** the same.
