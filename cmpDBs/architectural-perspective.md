# Architectural perspective on ACE

## Terms

Table comparison
SoT - source of truth
Session - postgres session with the following settings forced:
`extra_float_digits = 3, TimeZone = 'UTC', DateStyle = ISO, IntervalStyle = postgres and bytea_output = hex`. The SQL_ASCII allowed if only it is set on each instance.

## Preliminaries

- Comparator based on the assumption that `input(output(value)) = value` is true for each datatype in the database.
- If a third-party type can have lossy output it is a problem of the database owner.
- We keep in mind potential option of cross-DBMS table comparison but not dive deeply into these problems.
- We consider PG12+.

## Row identification

In relational database physical layer is separated from the relational one. So, the only identifier that exists for us is the same primary key or unique index (or full row value in case we will add a method for non-indexed tables).

**The same index**

```markdown
For a table comparator, unique indexes on two tables are the same if:

- they are valid, non-partial and contain no expressions;
- their key columns (excluding INCLUDE columns) match by name and are in the same order;
- each key column has the same opclass and the same sort direction;
- each key column is NOT NULL, or the index is NULLS NOT DISTINCT;
- each text key column uses the same deterministic collation, with the same collation version on both nodes.
```

To compare rows we download it to a client application. The language/hardware platform might not have an analogue for postgres types and we need to invent some tricks. Why not to compare rows inside PostgreSQL at first? - because we might have different PGVERs/settings or want to compare postgresql table with the same one in different DBMS.
The best answer is to match serialised representation of values prepared by output(value) command. There are potential artifacts might exist. For postgres it might be difference in semantic of EQ(val1,val2) operator and EQ(out(val1),out(val2)). For example, `-0 = 0`, but `'-0' <> '0'`.

Basically, we warn users if a comparison index contains a column of such datatype, but doesn't forbid operation itself. We should identify a problem if it happens. The problem may come in the following case:

N1 has x = -0, N2 has x = 0, x - key column.
Comparator detects that one row does not exist on the other server. Depending on strategy it takes action. Let's imagine N1 is a SoT, we need to add one row on N2 and delete another one:

```sql
DELETE FROM n2_table WHERE x = '0'::float8;
INSERT INTO n2_table (x) VALUES ('-0'::float8);
```

No problem unless we call INSERT at first. But for biderectional strategy, when we want to add absent row to each node:

```sql
INSERT INTO n2_table (x) VALUES ('0'::float8);
INSERT INTO n2_table (x) VALUES ('-0'::float8);
```

we will have a problem. To be sure we do not loose data we must:
1. Do all these changes in a single transaction and abort the command in case any command has failed. Failed means command caused an ERROR or doesn't touch exactly one row (zero or more than one is an error).
2. Do exact operation needed - no any alternatives ON CONFLICT or updates if we actually need INSERT.

## Key manipulation

We download to client each serialised key as a separated entity. It is necessary if we later need to touch the same row on the instance. We do it using the filter:

```sql
SELECT/UPDATE/DELETE ... WHERE x = $1::T AND format('%s', x) COLLATE "C" = format('%s', $1::T) AND y = ...
```
This form has two issues: if types are different (like, x is float8 on N1 and numeric on N2) and if a man-in-the-middle rewrote output value to a non-canonical form. Like: 42 -> 042. In such a case we might hide the difference. But it should be treated as unusual an out of the scope.