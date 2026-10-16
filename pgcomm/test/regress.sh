#!/bin/bash
#
# Self-comparison on the PostgreSQL regression database.
#
# 1. Starts a container from the stock postgres image.
# 2. Inside it, downloads the source of exactly the same server version,
#    builds the regression suite and runs `make installcheck`. Test
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
#
# Usage: test/regress.sh            (from the pgcomm directory)
#        IMAGE=postgres:18 KEEP=1 test/regress.sh   (keep the container)
#        JOBS=8 test/regress.sh     (workers of the parallel pass)
#        MEM=1MB test/regress.sh    (block size of the hash strategy)

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

echo "--- starting $IMAGE"
docker run -d --name "$NAME" -p 127.0.0.1::5432 \
	-e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
until docker exec "$NAME" pg_isready -q -U postgres 2>/dev/null; do sleep 1; done
# The entrypoint restarts the server once after initialisation.
sleep 3
until docker exec "$NAME" pg_isready -q -U postgres 2>/dev/null; do sleep 1; done

VERSION=$(docker exec "$NAME" postgres -V | awk '{print $3}')
echo "--- server version $VERSION"

echo "--- installing build tools"
# Since PG 17 the source tarball no longer ships generated files, so the
# build needs bison, flex and perl.
docker exec -e DEBIAN_FRONTEND=noninteractive "$NAME" sh -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential bison flex perl >/dev/null'

# The tarball is cached on the host: the download is the slowest and the
# least reliable step, and the same version is needed run after run.
CACHE=${CACHE:-$HOME/.cache/pgcmp}
TARBALL=$CACHE/postgresql-$VERSION.tar.gz
if [ ! -s "$TARBALL" ]; then
	echo "--- downloading postgresql-$VERSION.tar.gz"
	mkdir -p "$CACHE"
	curl -fsSL --retry 3 --connect-timeout 20 --speed-limit 10000 --speed-time 30 \
		-o "$TARBALL.part" "https://ftp.postgresql.org/pub/source/v$VERSION/postgresql-$VERSION.tar.gz"
	mv "$TARBALL.part" "$TARBALL"
fi
docker cp "$TARBALL" "$NAME:/tmp/src.tar.gz"
docker exec "$NAME" chown postgres /tmp/src.tar.gz

echo "--- building the regression suite from postgresql-$VERSION sources"
docker exec -u postgres -w /tmp "$NAME" sh -c "
	set -e
	tar xzf src.tar.gz
	cd postgresql-$VERSION
	./configure -q --prefix=/usr/lib/postgresql/${VERSION%%.*} --without-icu --without-readline --without-zlib >/dev/null
	make -s -C src/interfaces/libpq >/dev/null   # pg_regress links against it
	make -s -C src/test/regress >/dev/null
"

echo "--- make installcheck (failures are expected and ignored)"
docker exec -u postgres -w "/tmp/postgresql-$VERSION" \
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
[ ${#failed[@]} -eq 0 ]
