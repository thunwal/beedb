#!/usr/bin/env bash
# Download a dump from Dropbox and restore it into the local Docker postgres.
# By default fetches the most recent beedb_*.dump in $DROPBOX_FOLDER.
#
# Usage:
#   bash scripts/restore_from_dropbox.sh                       # latest
#   bash scripts/restore_from_dropbox.sh beedb_20260703T013000.dump

set -eo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found in $(pwd)" >&2
    exit 1
fi

# Parse .env with docker-compose semantics rather than `source`: values are
# literal strings, so passwords with (, ), $, spaces, etc. don't need shell
# escaping in the same file docker-compose reads.
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$val" == \"*\" ]]; then
        val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' ]]; then
        val="${val:1:${#val}-2}"
    fi
    export "$key=$val"
done < .env

: "${DROPBOX_APP_KEY:?DROPBOX_APP_KEY missing in .env}"
: "${DROPBOX_APP_SECRET:?DROPBOX_APP_SECRET missing in .env}"
: "${DROPBOX_REFRESH_TOKEN:?DROPBOX_REFRESH_TOKEN missing in .env}"
: "${DROPBOX_FOLDER:=/beedb-backups}"

FILE="${1:-}"

BACKUP_DIR="$(pwd)/backups"
mkdir -p "$BACKUP_DIR"

echo "==> Requesting Dropbox access token"
token_resp=$(curl -s https://api.dropbox.com/oauth2/token \
    -d grant_type=refresh_token \
    -d refresh_token="$DROPBOX_REFRESH_TOKEN" \
    -u "${DROPBOX_APP_KEY}:${DROPBOX_APP_SECRET}" || true)
TOKEN=$(jq -r '.access_token // empty' <<< "$token_resp" 2>/dev/null || true)
if [[ -z "$TOKEN" ]]; then
    echo "ERROR: failed to obtain Dropbox token: ${token_resp:0:200}" >&2
    exit 1
fi

if [[ -z "$FILE" ]]; then
    echo "==> Finding latest backup in ${DROPBOX_FOLDER}"
    list_resp=$(curl -s -X POST https://api.dropboxapi.com/2/files/list_folder \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"${DROPBOX_FOLDER}\"}" || true)

    if ! jq -e '.entries' <<< "$list_resp" >/dev/null 2>&1; then
        echo "ERROR: list_folder failed: ${list_resp:0:200}" >&2
        exit 1
    fi

    FILE=$(jq -r '.entries[] | select(.[".tag"]=="file") | .name' <<< "$list_resp" \
        | grep -E '^beedb_[0-9]{8}T[0-9]{6}\.dump$' \
        | sort | tail -1)

    if [[ -z "$FILE" ]]; then
        echo "ERROR: no beedb_*.dump files found in ${DROPBOX_FOLDER}" >&2
        exit 1
    fi
fi

OUT="${BACKUP_DIR}/${FILE}"
echo "==> Downloading ${DROPBOX_FOLDER}/${FILE} to ${OUT}"
curl -s --fail -X POST https://content.dropboxapi.com/2/files/download \
    -H "Authorization: Bearer $TOKEN" \
    -H "Dropbox-API-Arg: {\"path\": \"${DROPBOX_FOLDER}/${FILE}\"}" \
    -o "$OUT"

if [[ ! -s "$OUT" ]]; then
    echo "ERROR: downloaded file is empty" >&2
    exit 1
fi

# pg_dump custom-format archives start with the magic string "PGDMP".
if ! head -c 5 "$OUT" | grep -q '^PGDMP'; then
    echo "ERROR: downloaded file is not a pg_dump custom archive:" >&2
    head -c 500 "$OUT" >&2
    echo "" >&2
    exit 1
fi

echo "==> Restoring $OUT"
bash scripts/restore.sh "$OUT"
