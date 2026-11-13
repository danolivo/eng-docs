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
| SQL_ASCII database | `createdb -E SQL_ASCII -l C -T template0 <name>` for node 2; node 1 is a UTF8 database. | X11 (`x11_sql_ascii`) |
| Scratch database, superuser | A database that can be dropped after the test. | K17 (`k17_broken_index`), R13 (`r13_read_only`) |
| Native logical replication | `wal_level = logical` on the publisher, then a restart. The two databases can be in one instance. | R14 (`r14_logical_replication`) |
| Extension | The extension is installed on both servers. | D10 (`d10_postgis`), S16 (`s16_timescaledb`, needs `shared_preload_libraries`) |
| Two versions of an extension | Two servers with different versions of hstore, citext, ltree, pgvector or PostGIS. | P17 (`p17_ext_versions`) |
| Two server versions | Two major versions, 14 or newer. For N16: one server of version 11 or older and one of 12 or newer. | X4 (`x04_versions`), N16 (`n16_float_text`) |
| Two collation versions | Two OS releases with different glibc or ICU versions, or two clusters made by `initdb` with different locale options. | P13 (`p13_collation`) |
| Upgrade | An old cluster and a new cluster of a newer major version, and `pg_upgrade`. | P1, P2, P3 (`p01_upgrade`), P8 (`p08_reg_types`) |
| Dump and restore | Node 2 does not exist before the test: it is made from a dump of node 1. | P18 (`p18_travel`) |
| Tool state between two steps | A tool that keeps its own state about a table (in ACE: a Merkle tree). | V3 (`v03_update_conflict`, `v03_update_conflict_step`), V2, P18 |

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
| P2, P3 | No script of their own: they are the main set on plain servers. P2 is any instance with `track_commit_timestamp = off` (the default). P3 is a comparison of every table of the database, where tables without a key, foreign tables and views must be listed as not compared. |
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

The scripts were run on PostgreSQL 18.6 with `track_commit_timestamp = on` and `wal_level = logical`. No comparison tool was run on them.

- Run in full, two times each: `x04_versions`, `n16_float_text`, `p13_collation`, `p17_ext_versions`, `p08_reg_types`, `k17_broken_index`, `r06_commit_ts`, `p15_commit_ts_lost`, `r13_read_only`, `r14_logical_replication`, `x11_sql_ascii`, `v03_update_conflict`, `p18_travel`, `p01_upgrade`. They ran on one server, so the differences that need two server versions or two OS releases were not seen. `p01_upgrade` ran with a dump and restore in place of the upgrade. The steps of a tool (`mtree`) were not run.
- Seen in these runs. K17: for the same key range an index scan gives 2132 rows and a sequential scan 2827; there are 2352 duplicate keys; `bt_index_check` reports the index; a dump of that database cannot restore the primary key. R6 and P15: the rows have the planned commit times and origins. R13: an INSERT is refused. R14: an INSERT of row 3 on the publisher makes the apply worker of the subscriber fail (`apply_error_count = 1`).
- Run only with smaller sizes: `d07_big_block`, `x09_big_values`, `v02_mass_diff`.
- Not run: `d10_postgis`, `s16_timescaledb`. The extensions were not installed.
- R6: on PostgreSQL 18 a frozen row still shows its commit time. A NULL commit time of a frozen row was not reproduced.

## Changing the cases

The sources are in `src/`, one file for each pair. `python3 ../gen.py` builds the pairs. The rules are in `../README.md`. The comment lines at the start of a source file become the head of both scripts.
