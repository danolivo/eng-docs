# eng-docs
Requirements specifications, Design specifications, Technical descriptions, Verification and validation plans, methods, etc.

## Documents

Documents are grouped by directory. Each entry links straight to the file on GitHub.

### Methods (`methods/`)

| Document | Language | Description |
| --- | --- | --- |
| [Plan quality by buffer counts: comparing runs of one benchmark](https://github.com/danolivo/eng-docs/blob/main/methods/dbms-page-based-quality-assessment-ru.md) | RU | A machine-independent way to compare PostgreSQL plan quality across builds and hosts on a static benchmark (1C on Tantor SE 18): pages read and written by query category (ANALYZE, INSERT INTO, plain queries), WAL volume as a stability check, what skews the counters, how to compare two runs, and how to configure the instance and statistics collection for such an analysis. |
| [Benchmarking table comparison tools: method and data](https://github.com/danolivo/eng-docs/blob/main/methods/table-compare-bench/table-compare-bench-en.md) | EN | How to build the narrow, wide and toast test tables (a deterministic bigint-key family and a composite-key family), plant known differences, fix the physical state of the tables (heap layout, visibility map) and run pgcmp, ACE, pg_comparator and pgCompare comparably; SQL scripts in `methods/table-compare-bench/sql/`. |
