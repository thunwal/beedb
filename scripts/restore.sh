#!/usr/bin/env bash
# Restore a .dump file produced by backup.sh
# Usage: bash scripts/restore.sh <path-to-file.dump>
set -euo pipefail

DUMP="${1:?Usage: $0 <path-to-file.dump>}"
[[ -f "$DUMP" ]] || { echo "File not found: $DUMP"; exit 1; }

docker compose cp "$DUMP" db:/tmp/restore.dump

docker compose exec db \
  pg_restore -U "${POSTGRES_USER:-beedb}" \
             -d "${POSTGRES_DB:-beedb}" \
             --clean --if-exists \
             -Fc /tmp/restore.dump

docker compose exec db rm /tmp/restore.dump
echo "Restore complete."
