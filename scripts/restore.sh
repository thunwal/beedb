#!/usr/bin/env bash
# Restore a .dump file produced by backup.sh.
# The target database is derived from the filename: <dbname>_YYYYMMDDTHHMMSS.dump
# The database is dropped and recreated before restore.
# Usage: bash scripts/restore.sh <path-to-file.dump>
set -euo pipefail

DUMP="${1:?Usage: $0 <path-to-file.dump>}"
[[ -f "$DUMP" ]] || { echo "File not found: $DUMP"; exit 1; }

BASENAME=$(basename "$DUMP")
if [[ ! "$BASENAME" =~ ^([A-Za-z_][A-Za-z0-9_-]*)_[0-9]{8}T[0-9]{6}\.dump$ ]]; then
    echo "ERROR: filename does not match <dbname>_YYYYMMDDTHHMMSS.dump: $BASENAME" >&2
    exit 1
fi
DB="${BASH_REMATCH[1]}"
PG_USER="${POSTGRES_USER:-postgres}"

echo "==> Restoring '$DB' from $DUMP"

echo "--> Dropping and recreating '$DB'..."
docker compose exec -T db psql -U "$PG_USER" -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}' AND pid <> pg_backend_pid();"
docker compose exec -T db psql -U "$PG_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS \"${DB}\";"
docker compose exec -T db psql -U "$PG_USER" -d postgres \
    -c "CREATE DATABASE \"${DB}\";"

echo "--> Restoring dump..."
# No --no-owner / --no-privileges: we want the original owners and grants
# (e.g. crohrbach_editor, geoserver_read_all) preserved. Restore will fail
# fast if a referenced role doesn't exist on this server.
docker compose exec -T db \
    pg_restore -U "$PG_USER" -d "$DB" --exit-on-error \
    < "$DUMP"

echo "Restore complete: $DB"
