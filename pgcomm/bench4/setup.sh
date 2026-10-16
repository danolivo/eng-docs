#!/bin/bash
# Local two-instance stand for the cold composite-key trial: pgcmp vs ACE 2.1.1.
#
#   setup.sh init    initdb n1/n2, config, start
#   setup.sh data    t_nb PK (n numeric, id bigint), t_bn PK (id bigint, n numeric)
#                    n = random(), id = bigserial, avg row ~256 B; generated on n1,
#                    copied to n2 in id order, then 10 mutations on n2 (gt table);
#                    t_b PK (id bigint) — the same rows as t_bn, single integer key
#   setup.sh tb      add t_b to an already loaded stand
#   setup.sh stop | start
#
# shared_buffers is clamped (SB, 16MB by default) so that almost every page of
# the 1+ GB table being read misses shared_buffers; run.py restarts both
# instances before every run. Loading runs with a larger shared_buffers.
set -euo pipefail
export LC_ALL=C LANG=C
R=${R:-$HOME/pgcmp-local}
N=${N:-4000000}
SB=${SB:-16MB}
P1=5611 P2=5612
PSQL="psql -X -q -v ON_ERROR_STOP=1 -h localhost -d bench"
log() { echo "$(date '+%F %T') $*"; }

conf() {
cat <<EOF
port = $1
listen_addresses = 'localhost'
shared_buffers = $SB
max_connections = 50
work_mem = 64MB
maintenance_work_mem = 1GB
wal_level = minimal
max_wal_senders = 0
max_wal_size = 8GB
fsync = off
synchronous_commit = off
full_page_writes = off
autovacuum = off
jit = off
max_parallel_workers_per_gather = 0
max_parallel_maintenance_workers = 4
random_page_cost = 1.1
track_io_timing = on
track_commit_timestamp = on
logging_collector = off
EOF
}

# t_b: the same rows as t_bn, PK (id) only, so pgcmp takes the merge path.
# Built on each node from its own t_bn in id order, so n2 carries the same
# 10 mutations (same ids) and both heaps have the same physical order.
build_tb() {
    for p in $P1 $P2; do
        $PSQL -p $p -1 -c "DROP TABLE IF EXISTS t_b" \
                       -c "CREATE TABLE t_b (id bigserial, n numeric, pad text)" \
                       -c "INSERT INTO t_b SELECT * FROM t_bn ORDER BY id" \
                       -c "SELECT setval('t_b_id_seq', (SELECT max(id) FROM t_b))" \
                       -c "ALTER TABLE t_b ADD PRIMARY KEY (id)" >/dev/null
    done
    $PSQL -p $P2 -c "DELETE FROM gt WHERE tbl = 't_b'" \
                 -c "INSERT INTO gt SELECT 't_b', id, cat FROM gt WHERE tbl = 't_bn'"
}

start() { for i in 1 2; do pg_ctl -D $R/n$i -l $R/n$i.log -w ${1:+-o "$1"} start >/dev/null; done; }
stop()  { for i in 1 2; do pg_ctl -D $R/n$i -m fast -w stop >/dev/null 2>&1 || true; done; }

case "$1" in
init)
    stop
    rm -rf $R/n1 $R/n2
    for i in 1 2; do
        initdb -D $R/n$i -A trust -E UTF8 --locale=C >/dev/null
        conf $([ $i = 1 ] && echo $P1 || echo $P2) >> $R/n$i/postgresql.conf
    done
    start
    for p in $P1 $P2; do
        createdb -h localhost -p $p bench
        psql -X -q -h localhost -p $p -d bench -c "CREATE EXTENSION pgcrypto" \
                                               -c "CREATE EXTENSION pg_prewarm" # ACE hashes; OS-cache warm-up
    done
    log "init done: $(psql -X -h localhost -p $P1 -d bench -Atc 'SELECT version()')"
    ;;
data)
    stop; start "-c shared_buffers=2GB"
    t0=$(date +%s)
    DDL="DROP TABLE IF EXISTS t_nb, t_bn, gt;
         CREATE TABLE t_nb (id bigserial, n numeric, pad text);
         CREATE TABLE t_bn (id bigserial, n numeric, pad text);"
    $PSQL -p $P1 -c "$DDL"
    $PSQL -p $P2 -c "$DDL"
    $PSQL -p $P1 -c "INSERT INTO t_nb (n, pad)
                     SELECT random()::numeric, substr(repeat(md5(random()::text), 7), 1, 208)
                       FROM generate_series(1, $N)" \
                 -c "INSERT INTO t_bn SELECT * FROM t_nb ORDER BY id" \
                 -c "SELECT setval('t_bn_id_seq', (SELECT max(id) FROM t_bn))"
    log "generated on n1 in $(( $(date +%s) - t0 ))s"
    for t in t_nb t_bn; do
        psql -X -h localhost -p $P1 -d bench -c "\copy (SELECT * FROM $t ORDER BY id) TO STDOUT" |
            psql -X -q -h localhost -p $P2 -d bench -c "\copy $t FROM STDIN"
    done
    for p in $P1 $P2; do
        $PSQL -p $p -c "SELECT setval('t_nb_id_seq', (SELECT max(id) FROM t_nb)), setval('t_bn_id_seq', (SELECT max(id) FROM t_bn))" >/dev/null
        $PSQL -p $p -c "ALTER TABLE t_nb ADD PRIMARY KEY (n, id)" -c "ALTER TABLE t_bn ADD PRIMARY KEY (id, n)"
    done
    log "copied + PKs in $(( $(date +%s) - t0 ))s"
    for p in $P1 $P2; do
        echo "n$p: $($PSQL -p $p -Atc "SELECT md5(string_agg(md5(t::text), '' ORDER BY id)) FROM t_nb t") \
$($PSQL -p $p -Atc "SELECT md5(string_agg(md5(t::text), '' ORDER BY id)) FROM t_bn t")"
    done
    # 10 mutations on n2, the same ids in both tables:
    # 3 updates of pad, 3 deletes, 4 inserts (two of them outside n's [0,1) range)
    for t in t_nb t_bn; do
        $PSQL -p $P2 <<EOF
CREATE TABLE IF NOT EXISTS gt (tbl text, id bigint, cat text);
WITH u AS (UPDATE $t SET pad = 'changed-' || pad WHERE id IN (1000, $N / 2, $N - 5) RETURNING id)
INSERT INTO gt SELECT '$t', id, 'updated' FROM u;
WITH d AS (DELETE FROM $t WHERE id IN (2000, $N / 3, $N - 100) RETURNING id)
INSERT INTO gt SELECT '$t', id, 'deleted' FROM d;
WITH i AS (INSERT INTO $t (n, pad)
           SELECT v, substr(repeat(md5(random()::text), 7), 1, 208)
             FROM unnest(ARRAY[-1, 2, 0.5, random()]::numeric[]) v RETURNING id)
INSERT INTO gt SELECT '$t', id, 'inserted' FROM i;
EOF
    done
    build_tb
    for p in $P1 $P2; do $PSQL -p $p -c "VACUUM (FREEZE, ANALYZE)" -c "CHECKPOINT"; done
    $PSQL -p $P2 -c "\copy (SELECT * FROM gt ORDER BY 1, 2) TO '$R/gt.csv' CSV"
    $PSQL -p $P1 <<'EOF'
SELECT c.relname, c.reltuples::bigint AS rows,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_indexes_size(c.oid)) AS pk,
       (SELECT round(avg(pg_column_size(x.*)), 1) FROM t_nb x) AS avg_row_b,
       (SELECT correlation FROM pg_stats WHERE tablename = c.relname AND attname = 'n') AS corr_n,
       (SELECT correlation FROM pg_stats WHERE tablename = c.relname AND attname = 'id') AS corr_id
  FROM pg_class c WHERE relname IN ('t_nb', 't_bn', 't_b') ORDER BY 1;
EOF
    stop; start
    log "data done in $(( $(date +%s) - t0 ))s; shared_buffers = $(psql -X -h localhost -p $P1 -d bench -Atc 'SHOW shared_buffers')"
    ;;
tb)
    # add t_b to an existing stand (data already loaded and mutated)
    stop; start "-c shared_buffers=2GB"
    t0=$(date +%s)
    build_tb
    for p in $P1 $P2; do $PSQL -p $p -c "VACUUM (FREEZE, ANALYZE) t_b" -c "CHECKPOINT"; done
    $PSQL -p $P2 -c "\copy (SELECT * FROM gt ORDER BY 1, 2) TO '$R/gt.csv' CSV"
    $PSQL -p $P1 -c "SELECT c.relname, c.reltuples::bigint AS rows, pg_size_pretty(pg_relation_size(c.oid)) AS heap,
                            pg_size_pretty(pg_indexes_size(c.oid)) AS pk,
                            (SELECT round(avg(pg_column_size(x.*)), 1) FROM t_b x) AS avg_row_b,
                            (SELECT correlation FROM pg_stats WHERE tablename = 't_b' AND attname = 'id') AS corr_id
                       FROM pg_class c WHERE relname = 't_b'"
    stop; start
    log "t_b done in $(( $(date +%s) - t0 ))s"
    ;;
start) start ;;
stop)  stop ;;
*) echo "usage: $0 init|data|tb|start|stop"; exit 2 ;;
esac
