# Comment filter

Scope: comments added, changed, or attached to changed code. Never touch unrelated code.
Output: 1) edited diff; 2) `COMMIT:` text moved out of code; 3) `DOCS:` missing/edited places from the trigger table; 4) `Headers: N/M`.

## Placement — one fact, one place
| Content | Place |
|---|---|
| User-visible behaviour, syntax, semantics, limits | SGML (authoritative) |
| Metadata that generates docs/UI | its source file only (`.dat`, `.txt`) |
| Message to the user at run time | `errmsg`/`errdetail`/`errhint` |
| API contract for extension authors | `src/include` header comment (+ internals SGML chapter if one exists) |
| Contract, invariants, why this way, why not the obvious way | code |
| Design, algorithm, locking/WAL protocol spanning files | dir README |
| What broke, alternatives tried, backpatch rationale, incompatibility, opinions, credits, hashes, links | commit |
| Full debate, benchmarks, rejected designs in detail | mailing-list thread (`Discussion:`) |
| Case a test catches, bug # | regression test comment |

Rules of thumb: reader is a user → SGML; reader is a developer → code/header/README; event → commit; deliberation → thread.
Goes stale when code changes → code; true forever as an event → commit.
Duplicate → keep the most local valid copy; elsewhere cut or point (`See README`, `See <func>()`). Code never paraphrases SGML.

## Triggers — change → required places
| Change | Must also touch |
|---|---|
| GUC | `guc_parameters.dat` (short_desc/long_desc), `postgresql.conf.sample` (003_check_guc enforces), `config.sgml` |
| SQL syntax/option | `ref/*.sgml` (synopsis feeds psql `\h`), psql tab completion, pg_dump if dumpable |
| SQL function/operator | `pg_proc.dat`/`pg_operator.dat` `descr` (→ `\df+`), `func/*.sgml` entry with example |
| Catalog column | column comment in `pg_*.h`, `catalogs.sgml` |
| System/stats view | `system_views.sql`, `system-views.sgml` or `monitoring.sgml` |
| Wait event | `wait_event_names.txt` only (generates SGML) |
| SQLSTATE | `errcodes.txt` only (generates appendix) |
| Client utility option | `--help` text, `ref/<tool>.sgml` |
| Hook, AM/FDW/tableam callback, node field | header comment; matching internals SGML chapter if the API is documented there |
| contrib module | `doc/src/sgml/<module>.sgml`; bump extension version and add upgrade script if SQL objects change |
| On-disk/WAL/protocol format | README of subsystem or `protocol.sgml`; commit says catversion/WAL-format bump |
| User-visible incompatibility | SGML + explicit commit paragraph (release notes are built from commits; don't edit `release-*.sgml`) |
| Build option | `meson_options.txt` description, `installation.sgml` |
| Bug fix, no visible behaviour change | code + test + commit; no SGML |
| Back-patched visible change | back-patch the SGML hunk too |

## Code comments
1. WHY, not WHAT; delete restatements.
   ✗ `/* Demolish the house */` ✓ `/* Caller must have verified the house is unoccupied */`
2. Target hidden dangers: what a later patch must not change, and why.
3. Laconic; existing PG terminology.
4. Present tense. No names, hashes, URLs, bug #, dates, "new/added/fix for".
   Exception: history blocking a tempting regression — "We used to X, allowing Y; now Z", no refs.
5. Flag intentional omissions, known warts ("dangerous, but historical"), open questions (`XXX`).
6. Kludge exit by version: "can go away once pre-vNN servers are out of support".
7. Logic changed → rewrite the whole block's comments; drop stale ones.
8. Non-obvious code without a comment is worse than a long comment — add one.
9. Hint for the user goes into `errhint`, not into a comment next to `ereport`.
10. `/* */` only; `/*----` keeps line breaks; pgindent-clean; ≤80 cols.

## Function headers (Docstring Coverage, threshold 80%)
≥80% of functions touched by the diff have a header. State the contract, not the implementation:
```
/*
 * func_name
 *		Returns/does X; requires Y.
 */
```
Mention args or side effects only when non-obvious. Only trivial static helpers may go without a header, and they count toward the 20%.

## COMMIT notes
Subject ≤64 chars. ¶1: problem as behaviour + function name. Then rejected options, "While here…", backpatch reason; refs = 9-char hash + context.
