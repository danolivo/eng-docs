# Reference data for tools that compare PostgreSQL tables

This repository holds small pairs of tables with known differences, the expected result of their comparison, and the rules of a test that uses them. Each pair is one case where a comparison tool can give a wrong answer. The repository holds no comparison tool and no test results.

A test is: load the data into two databases, run a tool on each pair of tables, and compare its answer with the expected result.

## Files

| Path | Purpose |
|---|---|
| `node1.sql`, `node2.sql` | The main set: one script for each side of the comparison. |
| `node3.sql` | Optional third node, only for the cases that need three nodes or another database encoding. |
| `special/` | Cases that need a special stand. They have their own rules in `special/README.md`. |
| `diff-problem-cases.md` | The catalog: every case, its tables and the expected result, for a person. |
| `expected.csv` | The expected numbers of every table of the main set, for a program. |
| `tools.md` | Tools that can be tested with this data. |
| `expected.py` | Helper. Computes the expected numbers from two loaded databases. It is the exact form of the rules below, and the check of a load. |
| `gen.py`, `src/`, `special/src/` | Helper. The sources of the scripts and of the catalog, and their generator. Needed only to change the cases. |

A test needs only the scripts, the catalog and `expected.csv`. The two helpers are not a part of the method.

## Terms

- **Node**: one database of the pair. Node 1 gets `node1.sql`, node 2 gets `node2.sql`.
- **Case**: one problem, with an ID such as `N1`. A case has one or more tables. A table name starts with the case ID in lower case: `num.n01_scale` belongs to the case N1.
- **Register**: the table `ref_meta.cases (case_id, tbl, expect)`, the same on every node. The column `expect` says in words what a correct comparison of node 1 and node 2 reports for the table.
- **Result of a comparison**: three numbers for a table. Rows only on node 1, rows only on node 2, and changed rows (the key exists on both nodes, another column differs).

## What is a correct result

Two rules of equality are possible, and for some tables they give different numbers.

- **Text rule.** A value is the text output of its type under these session settings: `client_encoding = UTF8`, `TimeZone = UTC`, `DateStyle = ISO, MDY`, `IntervalStyle = postgres`, `extra_float_digits = 1`, `bytea_output = hex`, `lc_monetary = C`. Rows are paired by the text of the key. Two values are equal when the texts are byte-equal. The texts in the register follow this rule.
- **Operator rule.** Rows are paired by the operator `=` of the key type. Two values differ when `IS DISTINCT FROM` says so. Under this rule `1.50` and `1.5` are one key, and `-0` equals `0`.

Both rules are correct. A tool must follow one of them for a whole table and say which one. `expected.csv` and the catalog give the numbers of both rules.

A table without a primary key has no pairs of rows. Its whole rows are compared as a set with counts: there are rows only on node 1 and rows only on node 2, and no changed rows.

For some tables a number alone is not the whole answer; the register says it in words:

- The definitions differ (a type, a key, a column, the kind of the relation). A tool can compare the common part, or refuse the table with a clear message. Both are right.
- The rows are equal, but something that the rows point to is not (a large object, a sequence). "Match" is right for the rows. A tool that says more is better.
- The table cannot be read on one node. The only right answer is an error for this table.

## Environment

1. PostgreSQL 18 on every node. Two tables of the main set use virtual generated columns.
2. A server built with ICU.
3. These extensions can be created: `citext`, `hstore`, `ltree`, `lo`, `btree_gist`, `postgres_fdw` (contrib) and `vector` (pgvector).
4. The scripts are run by a superuser.
5. Node 1 and node 2 are UTF8 databases with the same default collation, and this collation is not `C`. Node 3 is a LATIN1 database.
6. The databases can be in one instance or in different instances.
7. The server accepts a connection of the loading role to `localhost` without a password. Only the foreign tables of the case S5 need it.

A load changes one thing outside its database: it creates the roles `ace_ref_reader` (LOGIN) and `ace_ref_other` (NOLOGIN) if they are not there.

## Procedure

### 1. Create the databases and load the data

```
createdb -T template0 -E UTF8 --locale-provider=icu --icu-locale=en-US n1
createdb -T template0 -E UTF8 --locale-provider=icu --icu-locale=en-US n2
psql -X -q -v ON_ERROR_STOP=1 -d n1 -f node1.sql
psql -X -q -v ON_ERROR_STOP=1 -d n2 -f node2.sql
```

For the third node, only when its cases are tested:

```
createdb -T template0 -E LATIN1 --locale-provider=libc -l C n3
psql -X -q -v ON_ERROR_STOP=1 -d n3 -f node3.sql
```

Rules:

- The scripts are plain SQL and work in the current database. Any database name is possible.
- A script can be run again. It first drops what an earlier run made, so a second run gives the initial state back.
- An error during a load means that the environment does not follow the rules above. Do not test on a database that was loaded with errors.

### 2. Check the load (optional)

```
./expected.py n1 n2 --check expected.csv
```

The helper computes the numbers of both rules from the two databases and compares them with the file. It needs both databases in one instance and takes the connection from the usual `PG*` variables. The last line must be `197 tables, 0 differ from expected.csv`.

### 3. List the tables and their keys

Most tools need the name of a table and its key columns. `expected.csv` has them in the columns `table` and `key`. The same list from the database:

```sql
SELECT r.tbl, c.relkind,
       (SELECT string_agg(quote_ident(a.attname), ',' ORDER BY k.ord)
          FROM pg_index i
          CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
         WHERE i.indrelid = c.oid AND i.indisprimary) AS key_columns
  FROM (SELECT DISTINCT tbl FROM ref_meta.cases) r
  LEFT JOIN pg_class c ON c.oid = to_regclass(r.tbl)
 ORDER BY 1;
```

Rules:

- Every table of the register is a part of the test, also a table without a primary key, a view, a materialized view, a foreign table and a partitioned table.
- Do not add a key or change a table to help the tool.
- The definition of a table can differ between the nodes on purpose. If the tool needs a key that exists only on one node, record what it does.

### 4. Run the tool

- Compare node 1 with node 2. Use node 3 only for the tables that `node3.sql` creates.
- Run one table at a time if the tool allows it. A failure on one table must not stop the test of the others.
- Use the default options of the tool. If an option is needed (a key, a block size, a limit of reported rows), record it.
- Do not set session parameters of the server for the tool. A tool that depends on them must show it.
- Connect as a superuser. For the cases S8, S9 and L7 connect as `ace_ref_reader`: these cases are about rows, columns and objects that this role cannot read.
- Set a time limit for each table. A run that goes over the limit is an error.
- A comparison must not change the data. If the tool creates its own objects in the compared databases, record it and load the data again before the next tool.
- Record the name and the version of the tool, the server version and the options.

### 5. Record the result

Write one line for each table:

- the verdict of the tool: match, differs, refused, or error;
- the number of rows only on node 1, only on node 2, and changed;
- the exit code and the text of the message, if there is one.

A tool that reports a changed row as one row on each side gives two numbers instead of three. Then a key that is reported on both sides counts as one changed row.

### 6. Judge the result

Take the expected numbers of the table from `expected.csv`:

| Column | Meaning |
|---|---|
| `table`, `kind_n1`, `kind_n2` | The relation and its kind on each node. |
| `key` | The key columns. Empty: whole rows are compared as a set. |
| `rows_n1`, `rows_n2` | The number of rows on each node. |
| `text_only_n1`, `text_only_n2`, `text_changed` | The result under the text rule. |
| `eq_only_n1`, `eq_only_n2`, `eq_changed` | The result under the operator rule. |
| `notes` | Differences of the definitions, and the reason of an empty number. |

Rules:

- The numbers of the tool must be equal to the numbers of one rule. The verdict alone is not enough.
- An empty number means that it cannot be computed; `notes` says why. Then read the words of the register for this table.
- When `notes` names a difference of the definitions, a refusal with a clear message is also right.
- A table can belong to more than one case. The catalog and the register show all cases of a table.
- The 2 catalog tables of the case L11 have no line in `expected.csv`. The numbers are for node 1 against node 2; a comparison with node 3 has no numbers. Judge these by the words of the register.
- Words of the register about a repair, a repair plan, or triggers during a repair describe a later step (see step 7). Skip them for a tool that only compares.

Put each result into one class:

| Class | Meaning |
|---|---|
| Correct | The numbers are the numbers of one rule, or the tool refused where a refusal is right. |
| Missed difference | The tool reports a match, or fewer rows than both rules. |
| False difference | The tool reports rows that are equal under both rules. |
| Error | The tool stops with a message where a result was possible. |
| Match after an error | The tool had an error and still reported a match. The worst class. |

If a tool uses a third rule of equality (rounding, trimming of spaces, a comparison without regard to case), record the rule next to its results. Such results are a property of the tool, not a random error.

### 7. Test a repair (optional)

Only for a tool that can change the data of one node to make it equal to the other.

- Load both nodes again before each repair test: a repair changes the data.
- The order is: compare, repair, compare again. The second comparison must report a match, except for the rows that the register names as failed.
- A row operation that fails must be reported. A repair that reports success and leaves a difference is wrong.
- Three cases have steps between the comparison and the repair or after it; the register describes them: R2 (change rows after the comparison), T18 (insert a row after the repair), X2 (other session defaults of a database; the commands are in comments at the end of `node2.sql`).

### 8. Clean

```
dropdb n1
dropdb n2
dropdb n3
psql -X -d postgres -c 'DROP ROLE ace_ref_reader, ace_ref_other'
```

The roles can be dropped only when no database of the instance holds the set any more.

## Special stands

21 cases cannot be shown by static data in two databases of one server. They need other server versions, a server setting, an extension, a lot of data, or steps between the scripts. Their scripts and rules are in `special/`. Their expected results are in the head of each script and in the second part of the catalog.

## Changing the cases

- Edit only the files in `src/` and `special/src/`. The scripts `node*.sql`, `special/*_node*.sql` and the catalog are generated: `python3 gen.py` builds all of them.
- A source file is plain SQL. The marks `\if :n1`, `\elif :n2`, `\else`, `\endif` at the start of a line choose the lines of one node. No other psql command is allowed.
- Keep both sides of a pair next to each other: the common rows first, then the rows of each node between the marks.
- One case is a comment `-- <ID>: <title>`, one or more tables, and one line `CALL ref_meta.reg(case, table, expect)` for each table. The line stands outside the marks, so the register is the same on every node. The comment becomes the title of the case in the catalog.
- Put a table into the schema of its group and start its name with the case ID.
- Write the expected result as the result of a correct comparison: `match`, or the number and the IDs of the rows that are changed, only on n1, only on n2. Add the repair result after it, if the case is about a repair.
- Write only what a reader needs for the test: no history of the case and no names of people, tasks or discussions.
- A script must be safe to run again. An object outside the schemas of the set must be dropped at the start of `src/00_setup.sql`.
- After a change: run `python3 gen.py`, load each script two times into scratch databases, run `./expected.py n1 n2 > expected.csv`, check the numbers of the changed tables by hand, and run `python3 gen.py` again to put them into the catalog.
