#!/usr/bin/env bash
#
# gen_big_table.sh -- (re)generate a wide synthetic table in PostgreSQL.
#
# Default shape: 3 000 000 000 rows, 440 GB heap as PostgreSQL reports it
# (pg_size_pretty(pg_relation_size()) and \dt+), no indexes, random data.
#
#   3 x uuid   (random, RFC 4122 version 4)
#   1 x date   (2015-01-01 .. 2025-12-31)
#   8 x numeric
#   4 x text   (hex code, currency, status, region)
#
# HOW THE SIZE IS PINNED
# Every row is built so that its heap tuple is 145..152 bytes long, which
# MAXALIGNs to exactly 152 bytes. With a 4-byte line pointer that is 156
# bytes per row, so exactly 52 rows fit an 8 kB page:
#     3e9 / 52 = 57 692 308 pages * 8192 = 440.16 GiB  ->  "440 GB".
# The trick is that every value has a fixed on-disk width:
#   - numerics have a fixed number of base-10000 digit groups
#     (e.g. amount = 10000.01 .. 99999999.99 is always 3 groups = 9 bytes);
#   - texts have fixed or narrowly varying lengths;
#   - event_date sits right after the uuids, so it is int4-aligned without
#     padding (after a text column it would get 0..3 bytes of padding);
#   - no NULLs, so no null bitmap.
# Change ROWS and the size scales linearly: size_GiB = ROWS / 52 * 8192 / 2^30.
# If you change the column list, re-check lp_len with pageinspect.
#
# Measured (PG 18.6, n2d-standard-16, 2x local NVMe RAID0, defaults):
#   load 43 min (1.16 M rows/s), VACUUM FREEZE 42 min;
#   3 000 000 000 rows, 57 692 407 pages, 52.00 rows/page,
#   pg_relation_size = pg_table_size = \dt+ = 440 GB.
# A resumed run (-r) keeps the dead space of the aborted chunks, so the
# table is slightly bigger; start from scratch if the exact size matters.
#
# Requirements: PostgreSQL >= 17 (random(min, max)), psql on the client.
#
# Server settings worth having for the load (not set by this script):
#   max_wal_size = 64GB, checkpoint_timeout = 30min, wal_compression = lz4,
#   shared_buffers >= 8GB. Free disk: ~440 GB for the table + max_wal_size.
#
# Usage:
#   PGHOST=... PGDATABASE=... ./gen_big_table.sh [options]
#     -t TABLE   table name                        (default: big_table)
#     -n ROWS    number of rows                    (default: 3000000000)
#     -j JOBS    parallel loader sessions          (default: nproc)
#     -c CHUNK   rows per transaction              (default: 10000000)
#     -m MODE    copy | insert   (default: copy for a logged table, insert for -U)
#     -U         create the table UNLOGGED (no WAL, ~1.5x faster, not crash-safe)
#     -r         resume an interrupted run instead of dropping the table
#     -F         skip the final VACUUM (FREEZE, ANALYZE)
#     -h         help
#
# Each chunk is committed together with a row in <table>_gen_progress, so a
# run killed half way can be continued with -r and never double-loads a chunk.
#
set -euo pipefail

TABLE=big_table
ROWS=3000000000
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
CHUNK=10000000
UNLOGGED=
RESUME=
FREEZE=1
MODE=

while getopts "t:n:j:c:m:UrFh" o; do
  case $o in
    m) MODE=$OPTARG ;;
    t) TABLE=$OPTARG ;;
    n) ROWS=$OPTARG ;;
    j) JOBS=$OPTARG ;;
    c) CHUNK=$OPTARG ;;
    U) UNLOGGED=UNLOGGED ;;
    r) RESUME=1 ;;
    F) FREEZE= ;;
    h|*) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0 ;;
  esac
done

[[ $TABLE =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "bad table name: $TABLE" >&2; exit 1; }
# COPY ... FROM STDIN uses multi-insert: one WAL record per page instead of
# one per row, which is what limits a logged load. Without WAL the plain
# INSERT ... SELECT is cheaper (no binary round trip through the client).
[[ -z $MODE ]] && { [[ -n $UNLOGGED ]] && MODE=insert || MODE=copy; }
[[ $MODE == copy || $MODE == insert ]] || { echo "bad mode: $MODE" >&2; exit 1; }
PROGRESS=${TABLE}_gen_progress
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1)
export PGOPTIONS="${PGOPTIONS:-} -c synchronous_commit=off -c max_parallel_workers_per_gather=0"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }

ver=$("${PSQL[@]}" -c "SHOW server_version_num")
(( ver >= 170000 )) || { echo "PostgreSQL >= 17 required (have $ver)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
if [[ -z $RESUME ]]; then
  log "dropping and creating $TABLE"
  "${PSQL[@]}" <<SQL
DROP TABLE IF EXISTS $TABLE;
DROP TABLE IF EXISTS $PROGRESS;
CREATE $UNLOGGED TABLE $TABLE (
    id              uuid          NOT NULL,
    parent_id       uuid          NOT NULL,
    correlation_id  uuid          NOT NULL,
    event_date      date          NOT NULL,  -- keep right after the uuids: no padding
    amount          numeric(15,2) NOT NULL,  -- 10000.01 .. 99999999.99, 9 bytes
    amount_net      numeric(15,2) NOT NULL,  -- same, 9 bytes
    price           numeric(12,2) NOT NULL,  -- 1.01 .. 9999.99, 7 bytes
    unit_cost       numeric(12,2) NOT NULL,  -- same, 7 bytes
    qty             numeric(10,0) NOT NULL,  -- 1 .. 9999, 5 bytes
    qty_shipped     numeric(10,0) NOT NULL,  -- same, 5 bytes
    tax_rate        numeric(6,4)  NOT NULL,  -- 0.0001 .. 0.9999, 5 bytes
    discount_rate   numeric(6,4)  NOT NULL,  -- same, 5 bytes
    code            text          NOT NULL,  -- 8 hex chars, ~4e9 distinct
    currency        text          NOT NULL,  -- 3 chars, 10 values
    status          text          NOT NULL,  -- 3..4 chars, 6 values
    region          text          NOT NULL   -- 2 chars, 8 values
) WITH (autovacuum_enabled = off);
CREATE TABLE $PROGRESS (chunk int PRIMARY KEY, nrows bigint NOT NULL,
                        done_at timestamptz NOT NULL DEFAULT now());
SQL
else
  log "resuming into existing $TABLE"
fi

# ---------------------------------------------------------------------------
# Row generator. Everything is integer arithmetic: random(int8,int8) and
# int8 -> numeric are cheap, float8 -> numeric goes through sprintf and is
# ~6x slower. The uuid is two random int8s with the v4 version/variant bits
# forced; it is ~2.5x cheaper than gen_random_uuid(), which asks the kernel
# CSPRNG for every value.
# ---------------------------------------------------------------------------
UUID="(lpad(to_hex((random(-9223372036854775808, 9223372036854775807) & ~61440::int8) | 16384::int8), 16, '0')
       || to_hex((random(-9223372036854775808, 9223372036854775807) & 4611686018427387903::int8) | (-9223372036854775808)::int8))::uuid"

gen_sql() {  # $1 = number of rows
  cat <<SQL
INSERT INTO $TABLE
SELECT $UUID, $UUID, $UUID,
       date '2015-01-01' + random(0, 4017),
       random(1000001, 9999999999)::numeric * 0.01,
       random(1000001, 9999999999)::numeric * 0.01,
       random(101, 999999)::numeric * 0.01,
       random(101, 999999)::numeric * 0.01,
       random(1, 9999)::numeric,
       random(1, 9999)::numeric,
       random(1, 9999)::numeric * 0.0001,
       random(1, 9999)::numeric * 0.0001,
       lpad(to_hex(random(0, 4294967295)), 8, '0'),
       (ARRAY['USD','EUR','GBP','JPY','CHF','CAD','AUD','CNY','SEK','NOK'])[random(1, 10)],
       (ARRAY['new','open','paid','sent','held','void'])[random(1, 6)],
       (ARRAY['EU','US','UK','JP','BR','IN','CA','AU'])[random(1, 8)]
FROM generate_series(1, $1)
SQL
}

# ---------------------------------------------------------------------------
# Parallel load: one transaction per chunk, chunk number recorded atomically.
# ---------------------------------------------------------------------------
NCHUNKS=$(( (ROWS + CHUNK - 1) / CHUNK ))
done_list=$("${PSQL[@]}" -c "SELECT chunk FROM $PROGRESS ORDER BY 1")
todo=()
for (( c = 0; c < NCHUNKS; c++ )); do
  grep -qx "$c" <<<"$done_list" || todo+=("$c")
done
log "rows=$ROWS chunk=$CHUNK chunks=$NCHUNKS todo=${#todo[@]} jobs=$JOBS mode=$MODE ${UNLOGGED:-LOGGED}"

run_chunk() {
  local c=$1 n=$CHUNK
  (( (c + 1) * CHUNK > ROWS )) && n=$(( ROWS - c * CHUNK ))
  if [[ $MODE == insert ]]; then
    { gen_sql "$n"; echo ";"
      echo "INSERT INTO $PROGRESS (chunk, nrows) VALUES ($c, $n);"; } \
      | "${PSQL[@]}" -1 -f -
  else
    set -o pipefail
    "${PSQL[@]}" -c "COPY ($(gen_sql "$n" | sed '1d')) TO STDOUT (FORMAT binary)" \
      | "${PSQL[@]}" -1 -c "COPY $TABLE FROM STDIN (FORMAT binary)" \
                        -c "INSERT INTO $PROGRESS (chunk, nrows) VALUES ($c, $n)"
  fi || { echo "chunk $c FAILED" >&2; return 255; }
}
export -f run_chunk gen_sql
export TABLE PROGRESS ROWS CHUNK UUID MODE
export PSQL_STR="${PSQL[*]}"

t0=$(date +%s)
if (( ${#todo[@]} > 0 )); then
  # progress line every 60 s
  ( while sleep 60; do
      read -r d r < <("${PSQL[@]}" -F' ' -c "SELECT count(*), coalesce(sum(nrows),0) FROM $PROGRESS")
      el=$(( $(date +%s) - t0 ))
      log "progress: $d/$NCHUNKS chunks, $r rows, $(( r / (el > 0 ? el : 1) )) rows/s overall"
    done ) &
  mon=$!
  trap 'kill $mon 2>/dev/null || true' EXIT
  printf '%s\n' "${todo[@]}" \
    | xargs -P "$JOBS" -I{} bash -c 'PSQL=($PSQL_STR); run_chunk {}'
  kill $mon 2>/dev/null || true
fi
t1=$(date +%s)
loaded=$("${PSQL[@]}" -c "SELECT coalesce(sum(nrows),0) FROM $PROGRESS")
[[ $loaded == "$ROWS" ]] || { echo "loaded $loaded rows, expected $ROWS; rerun with -r" >&2; exit 1; }
log "load done in $(( t1 - t0 )) s ($(( ROWS / ((t1 - t0) > 0 ? (t1 - t0) : 1) )) rows/s)"

# ---------------------------------------------------------------------------
# Finish: freeze + statistics, re-enable autovacuum, report size.
# VACUUM FREEZE rewrites every page once (hint bits + frozen xmin), so later
# scans don't do it behind your back; it is single-threaded on the heap.
# ---------------------------------------------------------------------------
if [[ -n $FREEZE ]]; then
  log "VACUUM (FREEZE, ANALYZE) $TABLE"
  "${PSQL[@]}" -c "VACUUM (FREEZE, ANALYZE) $TABLE"
else
  log "ANALYZE $TABLE"
  "${PSQL[@]}" -c "ANALYZE $TABLE"
fi
"${PSQL[@]}" -c "ALTER TABLE $TABLE RESET (autovacuum_enabled)"
"${PSQL[@]}" -c "DROP TABLE $PROGRESS"
t2=$(date +%s)
log "finish done in $(( t2 - t1 )) s; total $(( t2 - t0 )) s"

psql -X -v ON_ERROR_STOP=1 <<SQL
SELECT '$TABLE'                                        AS table,
       $ROWS::bigint                                   AS rows,
       pg_relation_size('$TABLE') / 8192               AS pages,
       round($ROWS::numeric / (pg_relation_size('$TABLE') / 8192), 2) AS rows_per_page,
       pg_size_pretty(pg_relation_size('$TABLE'))      AS heap,
       pg_size_pretty(pg_table_size('$TABLE'))         AS table_size,
       pg_size_pretty(pg_total_relation_size('$TABLE')) AS total;
\dt+ $TABLE
SQL
