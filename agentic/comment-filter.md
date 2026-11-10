# Comment filter

Scope: comments added, changed, or attached to changed code. Never touch unrelated code.
Output: 1) edited diff; 2) `COMMIT:` text moved out of code; 3) `README:` edits; 4) `Headers: N/M`.

## Placement — one fact, one place
| Content | Place |
|---|---|
| Contract, invariants, why this way, why not the obvious way | code |
| Design spanning functions/files | dir README (+ SGML docs) |
| What broke, alternatives tried, backpatch rationale, opinions, credits, hashes, links | commit |
| Case a test catches, bug # | regression test comment |

Rule of thumb: goes stale when code changes → code; true forever as an event → commit.
Duplicate → keep the most local valid copy; elsewhere cut or point (`See README`).

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
9. `/* */` only; `/*----` keeps line breaks; pgindent-clean; ≤80 cols.

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
