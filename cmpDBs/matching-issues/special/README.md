# Cases that need a special stand

The main set (`../node1.sql`, `../node2.sql`) covers the cases that static data in two databases of one server can show. A case is here when it needs something more: another server version, a server setting, an extension, a lot of data, or steps between the scripts.

The rules of `../README.md` apply here too. This file adds only what is different.

## Rules

- Each case is a pair `<name>_node1.sql` and `<name>_node2.sql`. Run them in the same way as the main scripts:

  ```
  psql -X -q -v ON_ERROR_STOP=1 -d <database of node 1> -f <name>_node1.sql
  psql -X -q -v ON_ERROR_STOP=1 -d <database of node 2> -f <name>_node2.sql
  ```

- The head of each script is the instruction of its case. It has three parts: `Stand` (what the servers need), `Run` (the steps and their order) and `Expect` (what a correct comparison reports). Read it before the run; it is the expected result of the case, there is no register here.
- All tables go to the schema `sp`. Each table also has a comment with the expected result: `\dt+ sp.*`.
- A pair does not need the main set, and the main set does not need any pair.
- A script can be run again. Two cases (R13, R14) have an undo script; the notes below say when to run it.
- Some scripts change more than their own tables: a database setting, catalog rows, a subscription, replication origins. Use the database that the table below asks for.
- The steps that name `mtree` or a repair are steps of one tool (ACE). For another tool, do the same kind of step if the tool has it, or skip the case.

## Stands

Prepare the stand of a group once, then run the pairs of the group.

| Stand | How to prepare | Cases (script name) |
|---|---|---|
| Any two databases, heavy load | Enough resources: see the note of each case. | D7 (`d07_big_block`), X9 (`x09_big_values`), V2 (`v02_mass_diff`) |
| Commit timestamps | `track_commit_timestamp = on` on both servers, then a restart. No real replication is needed: the scripts set commit times and origins through the replication origins `ace_ref_peer` and `ace_ref_history`. The scripts stop at once if the setting is off. | R6 (`r06_commit_ts`), P15 (`p15_commit_ts_lost`) |
| SQL_ASCII database | `createdb -T template0 -E SQL_ASCII --locale-provider=libc -l C <name>` for node 2; node 1 is a UTF8 database. | X11 (`x11_sql_ascii`) |
| Scratch database, superuser | A database that can be dropped after the test. | K17 (`k17_broken_index`), R13 (`r13_read_only`) |
| Native logical replication | `wal_level = logical` on the publisher, then a restart. The two databases can be in one instance. | R14 (`r14_logical_replication`) |
| Extension | The extension is installed on both servers. | D10 (`d10_postgis`), S16 (`s16_timescaledb`, needs `shared_preload_libraries`) |
| Two versions of an extension | Two servers with different versions of hstore, citext, ltree, pgvector or PostGIS. | P17 (`p17_ext_versions`) |
| Two server versions | Two major versions, 14 or newer. For N16: one server of version 11 or older and one of 12 or newer. | X4 (`x04_versions`), N16 (`n16_float_text`) |
| Two collation versions | Two OS releases with different glibc or ICU versions, or two clusters made by `initdb` with different locale options. | P13 (`p13_collation`) |
| Upgrade | An old cluster and a new cluster of a newer major version, and `pg_upgrade`. | P1, P2, P3 (`p01_upgrade`), P8 (`p08_reg_types`) |
| Dump and restore | Node 2 does not exist before the test: it is made from a dump of node 1. | P18 (`p18_travel`) |
| Tool state between two steps | A tool that keeps its own state about a table (in ACE: a Merkle tree). For ACE each node must be in its own instance: `mtree` uses a replication slot with a fixed name, and such a name is unique in an instance, not in a database. | V3 (`v03_update_conflict`, `v03_update_conflict_step`), V2, P18 |

Notes for single cases:

| Case | Note |
|---|---|
| D7 | 300000 rows of 4000 characters. Compare the whole table as one block, if the tool has blocks. |
| X9 | One bytea of 600 MB and one row of 1.2 GB of text. The server needs about 4 GB of free memory for the load. |
| V2 | Two tables of a million rows, about 100 MB for each node. |
| K17 | The node 1 script changes two catalog rows of its own table by hand, to break its primary key index. It prints how many duplicate keys the broken index let in. |
| R13 | The node 2 script makes its database read-only for new sessions. `r13_read_only_undo.sql` makes it writable again. |
| R14 | Node 1 is the publisher, node 2 the subscriber. Edit the connection string in the node 2 script (one marked line) before the run. To run the case again: `r14_logical_replication_undo.sql` on node 2, then the node 1 script, then the node 2 script. |
| P1 | Use `pg_upgrade --copy` or `--clone`. With `--link` the old cluster cannot be started again, so there is nothing to compare with. |
| P2, P3 | No script of their own: they are the main set on plain servers. P2 is any instance with `track_commit_timestamp = off` (the default). P3 is a comparison of every table of the database, where tables without a key, foreign tables and views must be listed as not compared. ACE compares a whole schema (`schema-diff`) only when the database has the same name on every node, so its nodes must be in different instances. |
| P8 | Only node 1 matters: `pg_upgrade --check` must refuse one of its tables. |
| V3 | Run the step pair in a way that is not replicated between the nodes. |

Two cases of this kind have their tables in the main set: V1 (`ver.v01_block_error`, one row of node 2 cannot be read) and V6 (`ver.v06_text_collisions`).

## Order of a test

1. Prepare the stand of the case.
2. Read the head of the script pair.
3. Run the scripts and the steps in the order that the head gives. Where the head puts a step of the tool between two scripts, keep this order.
4. Run the comparison and record the result as in `../README.md`.
5. Judge the result against the `Expect` part of the head.
6. Run the undo script, if the case has one, and drop the scratch databases.

## State of the scripts

Every pair was run in full on PostgreSQL 18.6 and 18.7 with `track_commit_timestamp = on` and `wal_level = logical`. The extensions were PostGIS 3.7.0 and TimescaleDB 2.32.0. The steps of a comparison tool are not a part of this state.

- Two server versions. `x04_versions` and `p17_ext_versions`: version 15 against 18. `n16_float_text`: version 11 against 18. `p01_upgrade`: `pg_upgrade --copy` from version 15 to 18.
- Two OS releases. `p13_collation`: version 15 on Ubuntu 18.04 (glibc 2.27, ICU 60) against version 15 on Debian 12 (glibc 2.36, ICU 72).
- Heavy pairs. `d07_big_block`, `x09_big_values` and `v02_mass_diff` were loaded in full size on servers with 16 GB of memory.
- Seen in these runs:
  - K17: for the same key range an index scan gives 2132 rows and a sequential scan 2827; there are 2352 duplicate keys; `bt_index_check` reports the index; a dump of that database cannot restore the primary key.
  - R6 and P15: the rows have the planned commit times and origins.
  - R13: an INSERT is refused.
  - R14: an INSERT of row 3 on the publisher makes the apply worker of the subscriber fail (`apply_error_count = 1`).
  - D10: the rows differ as the head of the script says; `ST_Equals` is true for the two lines of row 2.
  - S16: 30 chunks on node 1 and 5 on node 2; no row is in the root table.
  - X4: with the same ICU locale on both servers only row 21 of `sp.x04_version_canary` differs; `sp.x04_new_values` has 2 rows only on the newer server.
  - P17: the versions of citext (1.6 / 1.8) and ltree (1.2 / 1.3) differ; the values of `sp.p17_ext_values` are equal.
  - N16: with `extra_float_digits = 3` 7 of 10 rows differ by text.
  - P13: with the glibc locale `en_US.UTF-8` 10 of 42 strings have another position in the sort order, and `sp.p13_text_key` holds the same rows. With the ICU locale `en-US` no string of this sample has another position.
- R6: on PostgreSQL 18 a frozen row still shows its commit time. A NULL commit time of a frozen row was not reproduced.

## Changing the cases

The sources are in `src/`, one file for each pair. `python3 ../gen.py` builds the pairs. The rules are in `../README.md`. The comment lines at the start of a source file become the head of both scripts.
