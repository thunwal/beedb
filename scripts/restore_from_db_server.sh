#!/usr/bin/env bash
# Pull databases from the old VM directly into the new Docker postgres.
# Run this on the NEW server.
#
# Prerequisite: run the preparatory key-install and sudoers steps documented in
# README.md ("Migrating data from the old server").
#
# Usage:
#   bash scripts/restore_from_db_server
#   OLD_SSH_USER=myuser bash scripts/restore_from_db_server
set -euo pipefail

SSH_KEY="$HOME/.ssh/beedb_migration"
OLD_SSH_USER="${OLD_SSH_USER:-ubuntu}"
DATABASES=(beecovie msculpturalis)

if [[ ! -f "$SSH_KEY" ]]; then
    echo "ERROR: Migration key not found at $SSH_KEY"
    echo "Follow the preparatory step in README.md to generate and install it."
    exit 1
fi

read -rp "Old server IP address: " OLD_HOST
[[ -n "$OLD_HOST" ]] || { echo "ERROR: No IP entered."; exit 1; }

PG_USER="${POSTGRES_USER:-postgres}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── Preflight ────────────────────────────────────────────────────────────────

echo "==> Checking SSH connectivity to old server..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "${OLD_SSH_USER}@${OLD_HOST}" true \
    || { echo "ERROR: Cannot SSH to ${OLD_SSH_USER}@${OLD_HOST}"; exit 1; }

echo "==> Checking Docker Compose stack..."
docker compose ps db | grep -q "Up" \
    || { echo "ERROR: db container is not running - start it with: docker compose up -d db"; exit 1; }

# ── Migrate roles (cluster-level, not in per-database pg_dump) ───────────────

echo ""
echo "==> Migrating roles from old server..."
# Transfer every role with its password EXCEPT the postgres role itself:
# without the filter, `ALTER ROLE postgres ... PASSWORD '...'` would overwrite
# the new server's postgres password (set via .env). The awk filter drops the
# CREATE/ALTER ROLE lines for postgres and lets everything else through.
# `[[:space:]]` after the name prevents matching roles like postgres_admin.
ssh -i "$SSH_KEY" "${OLD_SSH_USER}@${OLD_HOST}" \
    "sudo -u postgres pg_dumpall --globals-only" \
  | awk '!/^(CREATE|ALTER) ROLE postgres[[:space:]]/' \
  | docker compose exec -T db psql -U "$PG_USER" -d postgres --set ON_ERROR_STOP=0 -q
echo "--> Roles done."

# ── Migrate each database ────────────────────────────────────────────────────

for DB in "${DATABASES[@]}"; do
    echo ""
    echo "================================================================"
    echo "  Migrating: $DB"
    echo "================================================================"

    echo "--> Dropping and recreating '$DB' on new server..."
    docker compose exec -T db psql -U "$PG_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}' AND pid <> pg_backend_pid();"
    docker compose exec -T db psql -U "$PG_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS \"${DB}\";"
    docker compose exec -T db psql -U "$PG_USER" -d postgres \
        -c "CREATE DATABASE \"${DB}\";"

    echo "--> Streaming dump from old server and restoring into Docker postgres..."
    # sudo -u postgres lets pg_dump connect via the local unix socket on the old VM
    ssh -i "$SSH_KEY" "${OLD_SSH_USER}@${OLD_HOST}" \
        "sudo -u postgres pg_dump -Fc \"${DB}\"" \
      | docker compose exec -T db \
        pg_restore -U "$PG_USER" -d "$DB" \
        --no-owner --no-privileges --exit-on-error

    echo "--> Done: $DB"
done

echo ""
echo "All done. Databases migrated: ${DATABASES[*]}"
