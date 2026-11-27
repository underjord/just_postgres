#!/bin/sh
#
# Smoke test a precompiled archive: unpack it somewhere new, create a cluster,
# start the server, run a few queries and stop it.
#
# Usage: scripts/smoke_test.sh just_postgres-port-<target>-<version>.tar.gz
#
# When run as root, PostgreSQL runs as `nobody` like it would on Nerves.

set -eu

ARCHIVE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=$(mktemp -d)
trap 'pg_ctl_stop; rm -rf "$WORK"' EXIT
chmod 755 "$WORK"

if [ "$(id -u)" = "0" ]; then
    RUN="setpriv --reuid=nobody --regid=nogroup --clear-groups"
else
    RUN=""
fi

as_user() {
    # shellcheck disable=SC2086
    $RUN env LD_LIBRARY_PATH="$WORK/pg/lib" LC_ALL=C "$@"
}

pg_ctl_stop() {
    if [ -f "$WORK/data/postmaster.pid" ]; then
        as_user "$WORK/pg/bin/pg_ctl" stop -D "$WORK/data" -m fast || true
    fi
}

cd "$WORK"
tar -xzf "$ARCHIVE"
mkdir data run
[ -n "$RUN" ] && chown nobody:nogroup data run

echo "== Linked libraries"
LD_LIBRARY_PATH="$WORK/pg/lib" ldd pg/bin/postgres

echo "== initdb"
as_user pg/bin/initdb -D "$WORK/data" -U postgres -E UTF8 --locale=C \
    --locale-provider=builtin --builtin-locale=C.UTF-8 --auth=trust \
    -c dynamic_shared_memory_type=sysv

echo "== start"
as_user pg/bin/pg_ctl start -D "$WORK/data" -w -l "$WORK/run/log" \
    -o "-c listen_addresses= -c unix_socket_directories=$WORK/run -p 54329"

echo "== queries"
as_user pg/bin/psql -h "$WORK/run" -p 54329 -U postgres -v ON_ERROR_STOP=1 -tA <<'SQL'
SELECT version();
SHOW ssl_library;
SET wal_compression = zstd;
CREATE TABLE squashed (body text COMPRESSION lz4);
INSERT INTO squashed SELECT repeat('x', 100000);
SELECT pg_column_compression(body) FROM squashed;
CREATE EXTENSION pgcrypto;
SELECT encode(digest('just_postgres', 'sha256'), 'hex');
SELECT now() AT TIME ZONE 'Europe/Stockholm' IS NOT NULL;
SQL

echo "== stop"
pg_ctl_stop
echo "Smoke test passed"
