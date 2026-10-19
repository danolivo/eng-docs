#!/bin/bash
#
# Self-comparison on the PostgreSQL regression database.
#
# 1. Derives a local image from the stock postgres image, once per server
#    version and base image: build tools and the regression suite compiled
#    from the source of exactly the same server version
#    (pgcmp-regress:<version>-<base image id>; REBUILD=1 rebuilds it).
# 2. Starts a container from it and runs `make installcheck`. Test
#    failures do not matter: we only need the "regression" database the
#    suite leaves behind.
# 3. Adds key tables (test/keytables.sql): for every column type in the
#    database that can be a primary key, a table keyed by that type and
#    filled with the distinct values the suite left in such columns.
# 4. Turns autovacuum off and analyses the whole database: the catalogs
#    are compared too and must not change between the snapshots of the two
#    sides, and every table gets a histogram for parallel mode.
# 5. Takes every table with a primary key, of any type and any number of
#    columns, catalogs included; only partitioned tables and inheritance
#    parents are left out (not supported yet). Each one is compared with
#    itself through two separate connections to the same database, once
#    sequentially and once with -j JOBS (4 by default). Anything but
#    "match" is a pgcmp bug. Single integer keys go through the merge
#    strategy, the rest through hash blocks; the blocks are tiny (MEM, 4kB
#    by default), so that every table with more than a few dozen rows is
#    cut into many blocks and its key values travel as block bounds.
# 6. Second pass (CROSS=0 skips it): test/oidshift.sql creates and drops one
#    object of every kind that takes an OID, to move the cluster-wide OID
#    counter; the suite runs again into database DB2 (regression2) of the
#    same instance and gets its key tables. Every table of the first
#    database with a primary key and the same structure in the second is
#    compared with its namesake there, sequentially and with -j JOBS. The
#    databases differ, so the check is not "match" but agreement with an
#    independent oracle: both tables read whole through psql, joined on the
#    client, and the report pgcmp should have written compared with the one
#    it wrote. Tables keyed by reg* columns (ordered by OID, which differs
#    between the databases) are reported as known and do not fail the run.
#
# Usage: test/regress.sh            (from the pgcomm directory)
#        IMAGE=postgres:18 KEEP=1 test/regress.sh   (keep the container)
#        JOBS=8 test/regress.sh     (workers of the parallel pass)
#        MEM=1MB test/regress.sh    (block size of the hash strategy)
#        CROSS=0 test/regress.sh    (self-comparison only)
#        DB2=other test/regress.sh  (name of the second database)

set -euo pipefail

IMAGE=${IMAGE:-postgres:18}
NAME=pgcmp-regress-$$
HERE=$(cd "$(dirname "$0")/.." && pwd)
BIN=$HERE/pgcmp
WORK=$(mktemp -d)

cleanup() {
	if [ "${KEEP:-0}" = 1 ]; then
		echo "container kept: $NAME"
	else
		docker rm -f "$NAME" >/dev/null 2>&1 || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "--- building pgcmp"
(cd "$HERE" && go build -o "$BIN")

# The server version decides which sources the suite is built from.
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
VERSION=$(docker run --rm --entrypoint postgres "$IMAGE" -V | awk '{print $3}')
echo "--- server version $VERSION ($IMAGE)"

# Build tools, sources and the compiled suite live in a local image derived
# from $IMAGE, built once and reused: installing the compilers is the
# slowest step (several minutes), and nothing in it changes from run to
# run. The tag carries the server version and the ID of the base image, so
# a new release or a re-pulled $IMAGE gets a fresh one. REBUILD=1 forces a
# rebuild. Old tags are not removed: `docker images pgcmp-regress`.
BASEID=$(docker image inspect --format '{{.Id}}' "$IMAGE" | sed 's/^sha256://' | cut -c1-12)
SUITE=pgcmp-regress:$VERSION-$BASEID
SRC=/opt/postgresql-$VERSION
if [ "${REBUILD:-0}" = 1 ] || ! docker image inspect "$SUITE" >/dev/null 2>&1; then
	# The tarball is cached on the host: the download is the least reliable
	# step, and the same version is needed run after run.
	CACHE=${CACHE:-$HOME/.cache/pgcmp}
	TARBALL=$CACHE/postgresql-$VERSION.tar.gz
	if [ ! -s "$TARBALL" ]; then
		echo "--- downloading postgresql-$VERSION.tar.gz"
		mkdir -p "$CACHE"
		curl -fsSL --retry 3 --connect-timeout 20 --speed-limit 10000 --speed-time 30 \
			-o "$TARBALL.part" "https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.gz"
		mv "$TARBALL.part" "$TARBALL"
	fi
	echo "--- building image $SUITE: build tools and the regression suite of postgresql-$VERSION"
	mkdir "$WORK/image"
	cp "$TARBALL" "$WORK/image/src.tar.gz"
	# Since PG 17 the source tarball no longer ships generated files, so the
	# build needs bison, flex and perl. pg_regress links against libpq.
	docker build -q -t "$SUITE" -f - "$WORK/image" >/dev/null <<DOCKERFILE
FROM $IMAGE
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \\
        --no-install-recommends build-essential bison flex perl >/dev/null \\
    && rm -rf /var/lib/apt/lists/*
COPY src.tar.gz /opt/src.tar.gz
RUN cd /opt && tar xzf src.tar.gz && rm src.tar.gz && chown -R postgres: $SRC
USER postgres
RUN cd $SRC \\
    && ./configure -q --prefix=/usr/lib/postgresql/${VERSION%%.*} --without-icu --without-readline --without-zlib >/dev/null \\
    && make -s -C src/interfaces/libpq >/dev/null \\
    && make -s -C src/test/regress >/dev/null
USER root
DOCKERFILE
else
	echo "--- reusing image $SUITE"
fi

echo "--- starting $SUITE"
docker run -d --name "$NAME" -p 127.0.0.1::5432 \
	-e POSTGRES_HOST_AUTH_METHOD=trust "$SUITE" >/dev/null
until docker exec "$NAME" pg_isready -q -U postgres 2>/dev/null; do sleep 1; done
# The entrypoint restarts the server once after initialisation.
sleep 3
until docker exec "$NAME" pg_isready -q -U postgres 2>/dev/null; do sleep 1; done

echo "--- make installcheck (failures are expected and ignored)"
docker exec -u postgres -w "$SRC" \
	-e PGHOST=/var/run/postgresql -e PGUSER=postgres "$NAME" \
	make -s -C src/test/regress installcheck >"$WORK/installcheck.log" 2>&1 || true
tail -3 "$WORK/installcheck.log"

PORT=$(docker port "$NAME" 5432/tcp | head -1 | sed 's/.*://')
DSN="host=127.0.0.1 port=$PORT user=postgres dbname=regression"

echo "--- key tables of every type"
psql -X -q -v ON_ERROR_STOP=1 -d "$DSN" -f "$HERE/test/keytables.sql" 2>&1 | sed 's/^.*NOTICE: *//'

# The catalogs are compared too: nothing may write to them between the
# snapshots of the two sides, and autovacuum would (pg_class.reltuples,
# pg_statistic). The database-wide ANALYZE gives every table a histogram.
echo "--- autovacuum off, ANALYZE"
psql -X -q -v ON_ERROR_STOP=1 -d "$DSN" \
	-c "ALTER SYSTEM SET autovacuum = off" -c "SELECT pg_reload_conf()" -c "ANALYZE" >/dev/null

# Every table with a primary key, catalogs included. Partitioned tables
# (relkind 'p') and inheritance parents are not supported yet; partitions
# and inheritance children are ordinary tables and stay.
psql -X -At -d "$DSN" >"$WORK/tables" <<'SQL'
SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
WHERE c.relkind = 'r'
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
  AND NOT EXISTS (SELECT FROM pg_inherits h WHERE h.inhparent = c.oid)
ORDER BY 1
SQL
psql -X -At -F ' ' -d "$DSN" >"$WORK/counts" <<'SQL'
SELECT count(*),
       count(*) FILTER (WHERE n.nspname IN ('pg_catalog', 'information_schema')),
       count(*) FILTER (WHERE c.relkind = 'p' OR EXISTS (SELECT FROM pg_inherits h WHERE h.inhparent = c.oid))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
SQL
read -r WITHPK CATALOG SKIPPED <"$WORK/counts"
echo "--- $WITHPK tables with a primary key ($CATALOG in the catalogs);" \
	"$SKIPPED partitioned or inheritance parents left out; $(wc -l <"$WORK/tables" | tr -d ' ') to compare"

PJOBS=${JOBS:-4}
ok=0
rows=0
par=0
hashed=0
blocks=0
keys=0
failed=()
while IFS= read -r t; do
	for j in 1 "$PJOBS"; do
		if "$BIN" -dsn1 "$DSN" -dsn2 "$DSN" -table "$t" -j "$j" -mem "${MEM:-4kB}" -out "$WORK/out" >"$WORK/log" 2>&1; then
			[ "$j" = 1 ] || { grep -q 'parallel:' "$WORK/log" && par=$((par + 1)); continue; }
			ok=$((ok + 1))
			rows=$((rows + $(sed -n 's/.*reference: \([0-9]*\) rows.*/\1/p' "$WORK/log")))
			blocks=$((blocks + $(sed -n 's/.*blocks: \([0-9]*\).*/\1/p' "$WORK/log" | grep . || echo 0)))
			if grep -q 'method: hash' "$WORK/log"; then hashed=$((hashed + 1)); fi
			case $t in pgcmp_keys.*) keys=$((keys + 1)) ;; esac
		else
			failed+=("$t -j $j")
			echo "FAIL $t -j $j"
			sed 's/^/    /' "$WORK/log"
			head -5 "$WORK/out" 2>/dev/null | cut -c1-300 | sed 's/^/    /'
			break
		fi
	done
done <"$WORK/tables"

echo "--- $ok matched ($keys key tables; $rows rows; $hashed by hash blocks in $blocks blocks of ${MEM:-4kB});" \
	"$par of them also in parallel with -j $PJOBS; ${#failed[@]} failed"
SELF_FAILED=${#failed[@]}

[ "${CROSS:-1}" = 1 ] || { [ "$SELF_FAILED" -eq 0 ]; exit; }

# ---------------------------------------------------------------------------
# Second pass: the same suite in another database of the same instance, and
# every table of the first database compared with its namesake in the second.
#
# The OID counter is cluster-wide. test/oidshift.sql first creates and drops
# one object of every kind that takes an OID, so the second run allocates
# everything after a gap and OIDs, relfilenodes, reg* values and enum label
# OIDs of the two databases interleave differently. The two databases are
# then far from equal: catalogs differ in OIDs, the suite leaves random and
# time-dependent data, concurrent test groups create objects in a different
# order. pgcmp is right if it reports exactly what an independent oracle
# finds, not if it finds nothing.

DB2=${DB2:-regression2}
DSN2="host=127.0.0.1 port=$PORT user=postgres dbname=$DB2"

echo "--- shifting the OID counter (test/oidshift.sql)"
psql -X -q -d "host=127.0.0.1 port=$PORT user=postgres dbname=postgres" \
	-f "$HERE/test/oidshift.sql" 2>&1 | sed -n -e 's/^.*WARNING: *\(oidshift:\)/\1/p' -e '/ERROR/p'

echo "--- make installcheck into $DB2 (failures are expected and ignored)"
docker exec -u postgres -w "$SRC" \
	-e PGHOST=/var/run/postgresql -e PGUSER=postgres "$NAME" \
	make -s -C src/test/regress installcheck EXTRA_REGRESS_OPTS="--dbname=$DB2" \
	>"$WORK/installcheck2.log" 2>&1 || true
tail -3 "$WORK/installcheck2.log"

echo "--- key tables of every type in $DB2"
psql -X -q -v ON_ERROR_STOP=1 -d "$DSN2" -f "$HERE/test/keytables.sql" 2>&1 | sed 's/^.*NOTICE: *//'
psql -X -q -v ON_ERROR_STOP=1 -d "$DSN2" -c "ANALYZE" >/dev/null

# One line per table with a primary key (same selection as above):
#   name ^_ signature ^_ key expression ^_ row expression ^_ reg
# The signature is the primary key and every column with its type; the pair
# is compared only if it is the same in both databases, otherwise pgcmp
# refuses or casts, and the oracle below does neither. The key and row
# expressions produce exactly the text pgcmp writes into its report: an
# integer key (merge) as is, any other as ROW(k1, k2, ...)::text with
# regproc/regoper keys through regprocedure/regoperator (unambiguousKeyType
# in schema.go); the row as ROW(non-key columns in attnum order)::text.
# "reg" marks a key with a reg* column: such keys are ordered by OID, and
# OIDs differ between the databases (README: what is not supported).
TABLEMETA=$(cat <<'SQL'
SELECT format('%I.%I', n.nspname, c.relname), chr(31),
       (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
          FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped)
       || ' | ' || k.names, chr(31),
       CASE WHEN k.n = 1 AND k.firsttype IN (20, 21, 23) THEN k.first || '::text'
            ELSE 'ROW(' || k.exprs || ')::text' END, chr(31),
       coalesce((SELECT 'ROW(' || string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) || ')::text'
                   FROM pg_attribute a
                  WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                    AND a.attnum <> ALL ((i.indkey::int2[])[0:i.indnkeyatts - 1])),
                '''()''::text'), chr(31),
       CASE WHEN k.reg THEN 'reg' ELSE '-' END
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
CROSS JOIN LATERAL (
	SELECT count(*) AS n,
	       string_agg(a.attname, ', ' ORDER BY p.ord) AS names,
	       string_agg(quote_ident(a.attname) ||
	                  CASE a.atttypid WHEN 24 THEN '::regprocedure' WHEN 2203 THEN '::regoperator' ELSE '' END,
	                  ', ' ORDER BY p.ord) AS exprs,
	       min(quote_ident(a.attname)) AS first,
	       min(a.atttypid) AS firsttype,
	       bool_or(t.typname LIKE 'reg%' AND t.typnamespace = 'pg_catalog'::regnamespace) AS reg
	FROM unnest((i.indkey::int2[])[0:i.indnkeyatts - 1]) WITH ORDINALITY AS p(attnum, ord)
	JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = p.attnum
	JOIN pg_type t ON t.oid = a.atttypid
) k
WHERE c.relkind = 'r'
  AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp%'
  AND NOT EXISTS (SELECT FROM pg_inherits h WHERE h.inhparent = c.oid)
ORDER BY 1
SQL
)
psql -X -At -F '' -d "$DSN" -c "$TABLEMETA" >"$WORK/meta1"
psql -X -At -F '' -d "$DSN2" -c "$TABLEMETA" >"$WORK/meta2"

# Pair the tables up by name: compared, structure differs, or only in the
# first database.
awk -F $'\037' 'FNR == NR { sig[$1] = $2; next }
	!($1 in sig) { gone++; next }
	sig[$1] != $2 { differ++; next }
	{ print }
	END { printf "%d %d\n", gone, differ > "/dev/stderr" }' \
	"$WORK/meta2" "$WORK/meta1" >"$WORK/cross" 2>"$WORK/crosscounts"
read -r GONE DIFFER <"$WORK/crosscounts"
echo "--- $(wc -l <"$WORK/meta1" | tr -d ' ') tables with a primary key in regression, $(wc -l <"$WORK/meta2" | tr -d ' ') in $DB2;" \
	"${GONE:-0} missing in $DB2, ${DIFFER:-0} of a different structure; $(wc -l <"$WORK/cross" | tr -d ' ') to compare"

# The oracle reads each table whole from both databases with pgcmp's own
# session settings (sessionSetup in schema.go), joins the two by key text on
# the client and prints the report pgcmp should have written: "match", or
# "<key> <reference row> <test row>" with NULL for a missing side. Fields
# and records are separated by \x1f and \x1e, so values may contain
# newlines; the report lines are compared as sorted multisets, which also
# copes with a newline breaking a report line (both sides break it alike).
SETUP="SET search_path = public; SET standard_conforming_strings = on; SET TimeZone = 'UTC';
SET DateStyle = 'ISO, YMD'; SET IntervalStyle = 'postgres'; SET bytea_output = 'hex';
SET extra_float_digits = 3; SET lc_monetary = 'C'; SET quote_all_identifiers = on;
SET client_encoding = 'UTF8'"
oracle_read() {   # dsn table keyexpr rowexpr file
	psql -X -q -t -A -F $'\037' -R $'\036' -d "$1" -c "$SETUP" -c "SELECT $3, $4 FROM $2" >"$5"
}
oracle_join() {   # reference test -> expected report
	awk -v RS=$'\036' '
		function rec(  r) { r = $0; sub(/\n$/, "", r); return r }
		FNR == NR { r = rec(); if (r == "") next; i = index(r, "\037")
		            ref[substr(r, 1, i - 1)] = substr(r, i + 1); next }
		{ r = rec(); if (r == "") next; i = index(r, "\037"); k = substr(r, 1, i - 1); v = substr(r, i + 1)
		  if (!(k in ref)) { printf "%s NULL %s\n", k, v; n++ }
		  else { if (ref[k] != v) { printf "%s %s %s\n", k, ref[k], v; n++ } delete ref[k] } }
		END { for (k in ref) { printf "%s %s NULL\n", k, ref[k]; n++ }
		      if (n == 0) print "match" }' "$1" "$2"
}

xok=0
xdiff=0
xrows=0
xlines=0
known=()
xfailed=()
while IFS=$'\037' read -r t sig kexpr rexpr reg; do
	oracle_read "$DSN" "$t" "$kexpr" "$rexpr" "$WORK/o1"
	oracle_read "$DSN2" "$t" "$kexpr" "$rexpr" "$WORK/o2"
	oracle_join "$WORK/o1" "$WORK/o2" | LC_ALL=C sort >"$WORK/expect"
	if [ "$(head -1 "$WORK/expect")" = match ]; then want=0; else want=1; fi
	for j in 1 "$PJOBS"; do
		rc=0
		rm -f "$WORK/out"
		"$BIN" -dsn1 "$DSN" -dsn2 "$DSN2" -table "$t" -j "$j" -mem "${MEM:-4kB}" -out "$WORK/out" >"$WORK/log" 2>&1 || rc=$?
		problem=
		if [ "$rc" != "$want" ]; then
			problem="exit code $rc, the oracle expects $want"
		elif ! LC_ALL=C sort "$WORK/out" | cmp -s - "$WORK/expect"; then
			problem="report differs from the oracle"
		fi
		if [ -z "$problem" ]; then
			[ "$j" = 1 ] || continue
			xok=$((xok + 1))
			[ "$want" = 0 ] || { xdiff=$((xdiff + 1)); xlines=$((xlines + $(wc -l <"$WORK/expect"))); }
			xrows=$((xrows + $(sed -n 's/.*reference: \([0-9]*\) rows.*/\1/p' "$WORK/log")))
			continue
		fi
		if [ "$reg" = reg ]; then
			known+=("$t -j $j: $problem")
			break
		fi
		xfailed+=("$t -j $j")
		echo "FAIL $t -j $j: $problem"
		grep -v 'query:' "$WORK/log" | sed 's/^/    /'
		LC_ALL=C sort "$WORK/out" 2>/dev/null | diff - "$WORK/expect" | head -6 | cut -c1-300 | sed 's/^/    /'
		break
	done
done <"$WORK/cross"

echo "--- regression vs $DB2: $xok agree with the oracle ($xrows rows in regression; $xdiff tables differ," \
	"$xlines report lines); ${#known[@]} with reg* keys disagree (not supported); ${#xfailed[@]} failed"
for k in ${known[@]+"${known[@]}"}; do echo "    known: $k"; done
[ "$SELF_FAILED" -eq 0 ] && [ ${#xfailed[@]} -eq 0 ]
