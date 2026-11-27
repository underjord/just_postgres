#!/bin/sh
#
# Smoke test a precompiled archive: unpack it somewhere new, create a cluster,
# start the server, run a few queries, then back it up with WAL-G, restore
# the backup into a new data directory and check that archived WAL was
# replayed.
#
# Usage: scripts/smoke_test.sh just_postgres-port-<target>-<version>.tar.gz
#
# When run as root, PostgreSQL runs as `nobody` like it would on Nerves.

set -eu

ARCHIVE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=$(mktemp -d)
trap 'pg_ctl_stop data; pg_ctl_stop restored; rm -rf "$WORK"' EXIT
chmod 755 "$WORK"

if [ "$(id -u)" = "0" ]; then
    RUN="setpriv --reuid=nobody --regid=nogroup --clear-groups"
else
    RUN=""
fi

as_user() {
    # shellcheck disable=SC2086
    $RUN env LD_LIBRARY_PATH="$WORK/pg/lib" LC_ALL=C \
        PGHOST="$WORK/run" PGPORT=54329 PGUSER=postgres PGDATABASE=postgres \
        WALG_FILE_PREFIX="$WORK/store" WALG_COMPRESSION_METHOD=zstd \
        WALG_PREVENT_WAL_OVERWRITE=true "$@"
}

psql() {
    as_user "$WORK/pg/bin/psql" -X -v ON_ERROR_STOP=1 -tA "$@"
}

pg_ctl_stop() {
    if [ -f "$WORK/$1/postmaster.pid" ]; then
        as_user "$WORK/pg/bin/pg_ctl" stop -D "$WORK/$1" -m fast || true
    fi
}

pg_ctl_start() {
    as_user "$WORK/pg/bin/pg_ctl" start -D "$WORK/$1" -w -l "$WORK/run/$1.log" \
        -o "-c listen_addresses= -c unix_socket_directories=$WORK/run -p 54329 \
            -c archive_mode=on -c archive_timeout=60 \
            -c 'archive_command=$WORK/pg/bin/wal-g wal-push %p' \
            -c 'restore_command=$WORK/pg/bin/wal-g wal-fetch %f %p'"
}

cd "$WORK"
tar -xzf "$ARCHIVE"
mkdir data restored run store
chmod 700 data restored
[ -n "$RUN" ] && chown nobody:nogroup data restored run store

echo "== Linked libraries"
LD_LIBRARY_PATH="$WORK/pg/lib" ldd pg/bin/postgres

echo "== initdb"
as_user pg/bin/initdb -D "$WORK/data" -U postgres -E UTF8 --locale=C \
    --locale-provider=builtin --builtin-locale=C.UTF-8 --auth=trust \
    -c dynamic_shared_memory_type=sysv

echo "== start"
pg_ctl_start data

echo "== queries"
psql <<'SQL'
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

echo "== WAL-G base backup"
as_user pg/bin/wal-g --version
as_user pg/bin/wal-g backup-push "$WORK/data"

echo "== WAL archiving"
psql -c "CREATE TABLE after_backup AS SELECT 'archived' AS note"
SEGMENT=$(psql -c "SELECT pg_walfile_name(pg_current_wal_lsn())")
psql -c "SELECT pg_switch_wal()" >/dev/null
for _ in $(seq 1 100); do
    ARCHIVED=$(psql -c "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver")
    if [ "$ARCHIVED" \> "$SEGMENT" ] || [ "$ARCHIVED" = "$SEGMENT" ]; then break; fi
    sleep 0.1
done
echo "archived up to $ARCHIVED"
pg_ctl_stop data

echo "== WAL-G restore"
as_user pg/bin/wal-g backup-fetch "$WORK/restored" LATEST
as_user touch "$WORK/restored/recovery.signal"
pg_ctl_start restored
for _ in $(seq 1 100); do
    [ "$(psql -c 'SELECT pg_is_in_recovery()')" = "f" ] && break
    sleep 0.1
done
NOTE=$(psql -c "SELECT note FROM after_backup")
[ "$NOTE" = "archived" ] || { echo "restored cluster is missing archived WAL"; exit 1; }

echo "== stop"
pg_ctl_stop restored
echo "Smoke test passed"
