# Tips and Tricks Extracted from the Skill Set

Four categories: develop, review, design/observe, test. The source skill is given in brackets. Each line keeps the skill's own rule rather than a paraphrase of its spirit.

## Develop

### Actual developer's methods

#### General

- Before writing:
-- Read the surrounding code for existing contexts, error style and naming; reuse before reinventing.
-- Analyse potential invariants that will be introduced or changed by this code. Propose defensive assertions to control them.

- "Look around": when you find one instance of a bug pattern, grep for the rest before declaring it fixed.

#### Parochial (community specifics)

- Split refactoring commits from feature commits; cleanup first, feature on top of a clean base.
- Prefer MemoryContext cleanup over `pfree()`: create a child context, switch in, work, switch back, destroy. Any callee can `elog(ERROR)` and longjmp past your frees.
- Three error tiers: `Assert()` for invariants, `elog(ERROR)` for "can't happen" bugs, `ereport(ERROR)` with an `errcode()` for user-visible errors.

### Tests

- Writing a regression test think about its output that might change because of a hardware/software platform. Also, relational relational database theory guarantees and its potential influence on the query result or explain.



### Not-Yet-Processed ones

- Never `palloc` between `START_CRIT_SECTION()` and `END_CRIT_SECTION()`. Use stack arrays or pre-allocated buffers; a failure there is a PANIC.
- Guard size, count and offset arithmetic with `pg_add_s32_overflow()`, `pg_mul_s64_overflow()` and friends.
- Message style: lowercase first letter, no trailing period, name the object type, "unrecognised"/"invalid" rather than "unknown"/"bad"; syscall details go in `errdetail()`.
- Comments explain danger, not the obvious: not `/* Demolish the house */` but `/* Caller must already have verified that the house is unoccupied */`.

- Switch on an enum: either no `default:` (so the compiler warns on new values) or `default: elog(ERROR, "unrecognised ...")`. Never `default: break`.
- Use C99 designated initialisers for tables indexed by enum.

- Call the same helper at the same point in every code path. Consistency over cleverness.
- Bundle related parameters into one ergonomic call instead of scattered function pairs (the `ShmemRequestStruct()` lesson).
- Header hygiene: no transitive include propagation; keep a `*defs.h` with types only.
- Commit message: imperative summary under 64 chars, body explains why, "In passing, also fix…" for opportunistic cleanup, a `Discussion:` link.
- Self-review in two voices (error paths/overflow vs consistency/ergonomics), then the defensive checklist, then propose patch decomposition.

### Defensive checklist (verbatim from `pg-code-writer`)

- Every `palloc` is in the right MemoryContext.
- No `palloc` inside critical sections.
- Integer arithmetic checked for overflow where sizes/counts are computed.
- `Assert()` on function preconditions (non-NULL pointers, valid enum values).
- Error paths don't leave data structures half-modified.
- `pfree` not relied upon for correctness (context reset handles cleanup).
- `LIST_FOREACH` loops don't modify the list being iterated.
- Switch statements on enums have no `default:` or `default: elog(ERROR, ...)`.
- Comments explain non-obvious constraints and danger zones.
- Error messages follow PostgreSQL conventions (lowercase, no period, errcode).

## 2. Review

Sources: `pg-code-review`, `tgl`, `andres-freund-reviewer`, `bcmills-concurrency-reviewer`, `crdb-go-reviewer`, `rsc-go-reviewer`.

### General method

- Read in this order: commit message → tests → docs → code. Tests reveal the author's intent and, more importantly, what isn't tested.
- First ask whether the patch pulls its weight at all. "Don't do this" is a legitimate verdict; don't review the implementation of a wrong design.
- Read for what's not there: outer joins, partitions, parallel query, GROUPING SETS, triggers, RLS, logical replication, NULLs, empty sets, zero rows.
- Trace ripple effects: parser → psql tab-completion; planner → EXPLAIN; executor → parallel query; catalog → pg_dump/pg_upgrade/information_schema; type system → client libraries.
- Backward-compatibility checklist: existing query output, pg_dump/restore both directions, pg_upgrade, extension ABI, wire protocol, a GUC for old behaviour, release notes.
- Every pointer dereference needs a NULL check or a proof. "It shouldn't be NULL" is not a proof.
- Any `palloc` in a per-row loop in a query-lifespan context is a leak; demand a per-tuple context with reset.
- pgindent is a precondition for review, not a nit. Reject diff noise (reformatting, cosmetic renames) because it pollutes `git blame`.
- Every finding carries: file/function/line, what goes wrong, a trigger (SQL or interleaving), impact, suggested fix. "Consider refactoring" is banned; say what to write instead.
- Review depth levels: quick (blockers only) / standard / thorough (propose the test for each finding).
- End with what's done well. Good patches deserve recognition.

### Performance and concurrency (Andres)

- Cost-model changes need benchmarks, not reasoning. Ask "have you measured…?" whenever a performance claim appears.
- Ask what happens under high concurrency: locks held across I/O, buffer pins held too long, O(n²) where O(n) exists, cache invalidation, snapshot handling.
- Code-clarity bar: can this be understood during a production incident at 3 am?
- Flag issues that only appear under specific workloads or configurations.

## 3. Design / observe

Sources: `pg-architect`, `kapila-architect`, `michael`, `science-advisor`, `lr-specs-writer`.

### Architecture (Robert Haas / Alvaro Herrera)

- Separate mechanism from policy: core provides mechanism, extensions implement policy.
- Infrastructure first, features second.
- Match the feature to a known pattern: access method, custom scan, bgworker, hook, catalog extension, GUC, event trigger, injection point, SPI.
- Extension-point preference order: method pointer in an existing struct → dedicated registration → GUC+SPI → generic hook (last resort).
- Crash-test the design: what if the server dies at every point in the new path? Is on-disk state valid between WAL records?
- Replication pass: does it generate WAL, work on a standby, have a logical decode path, survive pg_basebackup?
- Strengthen an abstraction rather than bypass it; metadata belongs in catalogs, not flat files or GUC-only config.
- Compare alternatives across named dimensions: granularity, operational reliability, crash safety, complexity, storage, platform independence.
- Ship working features with documented limitations rather than waiting for the theoretical optimum.

### Feature evolution and operations (Amit Kapila)

- Plan the multi-release story: what is the minimal increment now, what does it enable in two releases?
- Worker lifecycle questions: what if a worker crashes mid-operation, if the launcher dies, how is progress reported, what is the shutdown sequence, what happens when `max_worker_processes` is exhausted?
- Use DSM segments for per-operation shared state, not permanent shared memory.
- Protocol changes must be negotiated; design for a PG17 subscriber talking to a PG15 publisher from day one.
- Target patches under ~500 lines; a 5000-line patch never gets committed.
- HA pass: failover, publisher switchover, cascading replication, mixed-version clusters during rolling upgrades.
- Operability: can a DBA diagnose it from pg_stat_* views without reading source? Are errors actionable? Can it be paused, resumed, reset at runtime?

### Strategic lenses (Stonebraker)

- Which workload exactly? Is the scope appropriately narrow?
- What overhead does the abstraction add? Could a simpler approach give 80% of the gain for 20% of the complexity?
- Is the data model right, or will workarounds compound?
- Does it hold on modern hardware (NVMe, large memory, many cores, NUMA)?
- Is an extension the right vehicle, or should this be contrib or a core patch?

### Scientific grounding (science-advisor)

- Cite or derive; demand complexity and error bounds and the assumptions behind them.
- State which assumptions PostgreSQL violates: sampling vs streaming, attribute independence, 1990s cost constants, worst-case vs average-case.
- Formal rigour always for correctness (isolation, recovery, concurrency) and estimator error bounds; usually for algorithm complexity; rarely for operational concerns.
- Label claims: proven / strongly supported / plausible / speculative.

### Specification writing (lr-specs-writer)

- Draw the state machine before prose. Enumerate every state, every transition, every error transition, and which persistent state changes at each.
- Write the failure-modes section before the happy path; it tells you what persistent state you need.
- Fill an interaction matrix (partitions, RLS, triggers, generated columns, large objects, sequences, TRUNCATE+FK, parallel apply, sync rep, cascading, 2PC), marking each as works / N/A / known limitation / TODO.
- Distinguish "deliberately out of scope" from "haven't thought about it yet".
- Write the implementation plan last; if it won't split into <500-line patches, the design is too coupled.
- Quantify: "WAL volume increases by approximately 2x" beats "WAL volume increases".

## 4. Test

There is no dedicated tester skill. `pg-code-writer` even says "for tests use a test-writer skill", and that skill does not exist. The rules below are scattered across the reviewers and the two benchmark skills.

### Regression and functional tests

- Cover the happy path, NULLs, empty sets, boundary values, error conditions, and verify error message text. [`pg-code-review`, `tgl`]
- Tests must not depend on costs or row counts unless that is the thing under test. [`pg-code-review`]
- Tests must pass with and without assertions, across locales, parallel and serial. [`pg-code-review`]
- The regression suite is the minimum bar; test planner changes against real-world schemas. [`tgl`]
- TAP tests for multi-process interactions; failure modes tested with `pg_terminate_backend`, `kill -9`, network-partition simulation. [`lr-specs-writer`]
- Injection points (PG17+) are the answer to "there is no way for a test to hit this path": add the hook, don't write a hopeful test. [`pg-architect`, `crdb-go-reviewer`]

### Go tests

- `go test -race -count=100 -run X`; a clean run only proves the tests do not exercise the race, and the report must say so. [`bcmills`]
- Fake clocks instead of sleeps; `t.Cleanup`; `synctest` where available. [`bcmills`]
- Log the random seed so a failure is reproducible; never rely on container startup ordering implicitly. [`crdb`]
- Required adversarial tests for data tools: node dies mid-operation, concurrent writers during a diff, empty table, one row, NULL in key, duplicate-looking keys, max-length values, non-ASCII, mixed collation. [`crdb`]
- "Passing once means nothing. Run it a hundred times with the failure injected." [`crdb`]

### Benchmark discipline: identical start state (`tantor-1c-warmup`)

- Every timed run starts from the same cache state: `sync` + `echo 3 > /proc/sys/vm/drop_caches`, empty `shared_buffers`, then prewarm a frozen list.
- Remove `autoprewarm.blocks` before the run, or the previous run's buffers come back at startup.
- `pg_prewarm` on a table warms neither its indexes nor its TOAST; each is a separate list entry.
- Keep the list under 90% of `shared_buffers`; past that, clock sweep evicts prewarmed pages and the final content depends on load order.
- Build the list from a delta of two statistics snapshots, not from one taken right after a restore (index builds skew the counters).
- Both sides of an A/B must show the same list hash and nearly the same number of loaded blocks.
- Do not trim the first minutes of a run from the results; the warm-up is what makes the start comparable.

### Benchmark discipline: measuring the right thing (`pgedge-gcloud`)

- Both arms on the same hardware. If forced to split, run one identical cell on both pairs and report the difference as the noise floor (GCE I/O varies 5–15%).
- Re-`initdb` for every cell of the matrix; it removes bloat, cache state, slot history and WAL size carried over.
- Push a canary row end to end before every timed run.
- Assert the property the variant is named for and abort if it does not hold (e.g. check `count(DISTINCT chunk_id)` in the TOAST relation; verify `relreplident`).
- Assert version-specific GUCs are actually active via `pg_settings`.
- Generate data as a deterministic function of the primary key, never `random()`.
- Keep pgbench scale comfortably above the client count, or you measure row-lock contention instead of replication.
- Do not trust `lag == 0` when the progress table is empty; wait against the publisher's `pg_current_wal_lsn()`.
- Compute lag with your own formula from raw columns; built-in definitions change between versions.
- Size disk for WAL, not data; never set `max_slot_wal_keep_size` on a lag benchmark.
- Raise `wal_sender_timeout` / `wal_receiver_timeout` well above 60 s; do not leave `shared_buffers` and `max_wal_size` at defaults or the run becomes checkpoint-bound.
- Size data for the mechanism, not for realism: the smallest size that still exceeds `shared_buffers`.
- Budget separately for the drain; catch-up can take longer than the load (600 s of load needed 1467 s of catch-up).
- Rotate the server log per run; write a stamp file per finished cell so a crash resumes instead of repeating paid work.
