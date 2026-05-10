#!/usr/bin/env bash
# Dump the database into ./backups/  (gitignored)
# Usage: bash scripts/backup.sh
set -euo pipefail

BACKUP_DIR="$(cd "$(dirname "$0")/.." && pwd)/backups"
mkdir -p "$BACKUP_DIR"

OUTFILE="$BACKUP_DIR/beedb_$(date +%Y%m%dT%H%M%S).dump"

docker compose exec -T db \
  pg_dump -U "${POSTGRES_USER:-beedb}" -Fc "${POSTGRES_DB:-beedb}" \
  > "$OUTFILE"

echo "Backup written to $OUTFILE"
