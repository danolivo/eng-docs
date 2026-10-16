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
# 4. Picks every table pgcmp can handle (ordinary table with a primary key
#    of any type) and compares each one with itself through two separate
#    connections to the same database. Anything but "match" is a pgcmp bug.
#    Single integer keys go through the merge strategy, the rest through
#    hash blocks; the blocks are tiny (MEM, 4kB by default), so that every
#    table with more than a few dozen rows is cut into many blocks and its
#    key values travel as block bounds.
#
# Usage: test/regress.sh            (from the pgcomm directory)
#        IMAGE=postgres:18 KEEP=1 test/regress.sh   (keep the container)
#        JOBS=4 test/regress.sh     (parallel mode where a histogram exists)
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

# Tables pgcmp accepts: ordinary tables (partitions included, partitioned
# parents excluded) with a primary key.
psql -X -At -d "$DSN" >"$WORK/tables" <<'SQL'
SELECT format('%I.%I', n.nspname, c.relname)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\_toast%'
ORDER BY 1
SQL
TOTAL=$(psql -X -At -d "$DSN" -c "
	SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	WHERE c.relkind IN ('r', 'p')
	  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
	  AND n.nspname NOT LIKE 'pg\_toast%'")
echo "--- $(wc -l <"$WORK/tables" | tr -d ' ') of $TOTAL tables are eligible"

ok=0
rows=0
par=0
hashed=0
blocks=0
keys=0
failed=()
while IFS= read -r t; do
	if "$BIN" -dsn1 "$DSN" -dsn2 "$DSN" -table "$t" -j "${JOBS:-1}" -mem "${MEM:-4kB}" -out "$WORK/out" >"$WORK/log" 2>&1; then
		ok=$((ok + 1))
		rows=$((rows + $(sed -n 's/.*reference: \([0-9]*\) rows.*/\1/p' "$WORK/log")))
		blocks=$((blocks + $(sed -n 's/.*blocks: \([0-9]*\).*/\1/p' "$WORK/log" | grep . || echo 0)))
		if grep -q 'parallel:' "$WORK/log"; then par=$((par + 1)); fi
		if grep -q 'method: hash' "$WORK/log"; then hashed=$((hashed + 1)); fi
		case $t in pgcmp_keys.*) keys=$((keys + 1)) ;; esac
	else
		failed+=("$t")
		echo "FAIL $t"
		sed 's/^/    /' "$WORK/log"
		head -5 "$WORK/out" 2>/dev/null | sed 's/^/    /'
	fi
done <"$WORK/tables"

echo "--- $ok matched ($keys key tables; $rows rows; $hashed by hash blocks in $blocks blocks of ${MEM:-4kB};" \
	"$par in parallel with -j ${JOBS:-1}), ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ]
