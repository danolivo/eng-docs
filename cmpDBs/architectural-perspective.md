# Architectural perspective on ACE

## Terms

- Table comparison
- SoT: source of truth.
- Session: a PostgreSQL session with the following settings forced: `extra_float_digits = 3, TimeZone = 'UTC', DateStyle = ISO, IntervalStyle = postgres and bytea_output = hex`. SQL_ASCII is allowed only if it is set on every instance.

## Preliminaries

- The comparator is based on the assumption that `input(output(value)) = value` holds for each data type in the database.
- Comparator doesn't cast incoming postgres-type values to its own types (avoid lossy conversions) and employs only simple byte equality operation.
- If a third-party type has a lossy output function, this is a problem of the database owner.
- We keep in mind a possible cross-DBMS table comparison, but we do not study its problems in detail.
- We consider PG12+.

## Row identification

In a relational database, the physical layer is separate from the logical one. So the only row identifier available to us is a primary key or a unique index that is the same on both tables (or the full row value, if we add a method for tables without an index).

**The same index**

```markdown
For a table comparator, unique indexes on two tables are the same if:

- they are valid, non-partial and contain no expressions;
- their key columns (excluding INCLUDE columns) match by name and are in the same order;
- each key column has the same opclass and the same sort direction;
- each key column is NOT NULL, or the index is NULLS NOT DISTINCT;
- each text key column uses the same deterministic collation, with the same collation version on both nodes.
```

To compare rows, we download them to a client application. The language or hardware platform of the client might have no analogue for some PostgreSQL types, and we would need to invent tricks. Why not compare rows inside PostgreSQL? Because the nodes might have different PostgreSQL versions or settings, or we might want to compare a PostgreSQL table with the same table in another DBMS.

The best answer is to compare the serialised representation of values that the output function gives, `output(value)`. This can produce artifacts. In PostgreSQL, the semantics of `EQ(val1, val2)` can differ from the semantics of `EQ(out(val1), out(val2))`. For example, `-0 = 0`, but `'-0' <> '0'`.

We warn users if the comparison index contains a column of such a data type, but we do not forbid the operation. We must detect the problem if it happens. The problem can appear in the following case:

N1 has x = -0, N2 has x = 0, and x is the key column.

The comparator finds two rows, and each of them exists on one server only. The action depends on the repair strategy. Suppose N1 is the SoT: we need to add one row on N2 and delete another row there:

```sql
DELETE FROM n2_table WHERE x = '0'::float8;
INSERT INTO n2_table (x) VALUES ('-0'::float8);
```

There is no problem unless we run the INSERT first. But with the bidirectional strategy, we add the absent row to each node:

```sql
INSERT INTO n1_table (x) VALUES ('0'::float8);
INSERT INTO n2_table (x) VALUES ('-0'::float8);
```

and we get a problem. To be sure that we do not lose data, we must:

1. Make all these changes in a single transaction, and abort the whole operation if any command fails. A command fails if it raises an ERROR or does not change exactly one row (zero rows or more than one row is an error).
2. Run exactly the operation that is needed: no ON CONFLICT clauses, and no UPDATE when we actually need an INSERT.

## Collations

We use indexes and the key order of the compared tables, so we depend on collations. The table is cut into blocks by key ranges in the key order of one node, and every node reads the rows of each range in its own order. If a node orders the key in another way, a row can fall into another block on that node. Then a block on one node holds a key that the same block on the other node does not hold, although the row exists on both nodes.

In practice, it is hard to prove that the order is the same on all nodes: it depends on collation definitions, library versions, composite types, enum labels and extension types. So we agree on the following strategy: we do not try to check every cause, we detect the effect.

1. Before the comparison, we check the obvious cases: the definitions of the key column collations (provider, locale, rules, determinism) must be the same on all nodes. If they differ, table-diff warns the user, and the Merkle tree stops (see the limits below). The version of the collation library is not checked: point 3 sees its effect.
2. When the keys of a block differ, we read the rows of the differing keys on both nodes by key, not by range. A row that exists on both nodes with the same hash is not a difference. So a key that falls into another block never goes to the report as an absent row.
3. With each row, the same query returns whether the key lies inside the range of the block in the order of this node. If a row is found by its key but lies outside the range, this node orders the key differently from the block bounds. We warn the user and write the warning into the result manifest; table-repair prints it before it changes any row. We do not change the report and do not block the repair: the user decides what to do.

The check in point 3 does not need a common snapshot of the two reads. The answer depends only on the block bounds, the key and the collation of the node, not on the time when the row appeared. A row that came by replication between the two reads lies inside the range if the order is the same, so it gives no false warning. A snapshot on each node would not protect against concurrent changes on the other node anyway, and it would hold the xmin horizon on every node.

Limits:

- The check sees a difference only when a key actually falls outside its block. If no key crosses a block bound, there is nothing to see, and also no harm.
- The check does not detect the difference between `output(v1) EQ output(v2)` and `v1 EQ v2` (`-0` and `0`, `1.0` and `1.00`). The row read compares the key text byte by byte, so such keys stay two different keys. Finding such pairs needs a lookup by type equality, and this is a separate problem.
- The Merkle tree finds the leaf of each change by comparing the key with the leaf bounds. If a change goes to a wrong leaf, the hash of its real leaf stays old and equal to the hash on the other node. The rows of this leaf are never read, and the check has nothing to see. For this reason, the Merkle tree keeps the stop on a collation mismatch.

This approach keeps the code simple: no catalog query for each kind of type definition, no extra query and no held snapshot. The check is one more column in the query that already reads the differing rows.

## Key manipulation

We download each serialised key to the client as a separate entity. We need it to find the same row on the instance later. We do it with the following filter:

```sql
SELECT/UPDATE/DELETE ... WHERE x = $1::T AND format('%s', x) COLLATE "C" = format('%s', $1::T) AND y = ...
```

This form has two issues: the types can differ (for example, x is float8 on N1 and numeric on N2), and a man-in-the-middle can rewrite an output value into a non-canonical form, for example 42 -> 042. In such cases we might hide a difference. We treat these cases as unusual and out of scope.
