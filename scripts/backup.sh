#!/usr/bin/env bash
# Dump beedb, upload to Dropbox, apply retention, mail the result.
# Meant to run daily from cron on the VM.
#
# Retention on Dropbox:
#   - every backup for the last 14 days (daily)
#   - the Monday backup for the last 60 days (weekly)
#   - the first-Monday-of-month backup for the last 365 days (monthly)
# Local: only the most recent dump is kept in ./backups/.

set -eo pipefail

# cron gives a minimal PATH; make sure docker, jq, ssmtp are reachable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
    echo "ERROR: .env not found in $(pwd)" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=beedb}"
: "${DROPBOX_APP_KEY:?DROPBOX_APP_KEY missing in .env}"
: "${DROPBOX_APP_SECRET:?DROPBOX_APP_SECRET missing in .env}"
: "${DROPBOX_REFRESH_TOKEN:?DROPBOX_REFRESH_TOKEN missing in .env}"
: "${DROPBOX_FOLDER:=/beedb-backups}"
: "${BACKUP_MAIL_FROM:=}"
: "${BACKUP_MAIL_TO:=}"

BACKUP_DIR="$(pwd)/backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%dT%H%M%S)
NAME="beedb_${TIMESTAMP}.dump"
OUTFILE="${BACKUP_DIR}/${NAME}"

STATUS="FAILED"
SUMMARY="script exited before finishing"

log() { printf '%s %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"; }

send_mail() {
    local subject="$1"
    [[ -z "$BACKUP_MAIL_FROM" || -z "$BACKUP_MAIL_TO" ]] && return 0
    if [[ ! -x /usr/sbin/ssmtp ]]; then
        log "ssmtp not installed, skipping mail"
        return 0
    fi
    local rcpt
    for rcpt in $BACKUP_MAIL_TO; do
        printf 'From: %s\nSubject: %s\n\n' "$BACKUP_MAIL_FROM" "$subject" \
            | /usr/sbin/ssmtp "$rcpt" 2>&1 \
            || log "Mail to $rcpt failed"
    done
}

on_exit() {
    local ec=$?
    if (( ec != 0 )) && [[ "$STATUS" == "OK" ]]; then
        STATUS="FAILED"
    fi
    send_mail "beedb backup | ${STATUS} | ${SUMMARY}"
}
trap on_exit EXIT

# ── 1. dump ───────────────────────────────────────────────────────────────────
log "Dumping ${POSTGRES_DB} to ${OUTFILE}"
docker compose exec -T db \
    pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "$OUTFILE"

if [[ ! -s "$OUTFILE" ]]; then
    SUMMARY="pg_dump produced an empty file"
    exit 1
fi
DUMP_BYTES=$(stat -c%s "$OUTFILE")
DUMP_KB=$(( (DUMP_BYTES + 1023) / 1024 ))
log "Dump size: ${DUMP_KB} KB"

# ── 2. Dropbox access token ───────────────────────────────────────────────────
log "Requesting Dropbox access token"
token_resp=$(curl -s https://api.dropbox.com/oauth2/token \
    -d grant_type=refresh_token \
    -d refresh_token="$DROPBOX_REFRESH_TOKEN" \
    -u "${DROPBOX_APP_KEY}:${DROPBOX_APP_SECRET}" || true)
TOKEN=$(jq -r '.access_token // empty' <<< "$token_resp" 2>/dev/null || true)
if [[ -z "$TOKEN" ]]; then
    SUMMARY="failed to obtain Dropbox token: ${token_resp:0:200}"
    exit 1
fi

# ── 3. upload ─────────────────────────────────────────────────────────────────
# Single-request upload; Dropbox limit is 150 MB. If the dump ever grows past
# that, switch to /2/files/upload_session/*.
log "Uploading ${NAME} to ${DROPBOX_FOLDER}"
upload_resp=$(curl -s --max-time 3600 -X POST \
    https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer ${TOKEN}" \
    --header "Dropbox-API-Arg: {\"path\": \"${DROPBOX_FOLDER}/${NAME}\",\"mode\": \"overwrite\",\"mute\": true}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary "@${OUTFILE}" || true)

uploaded_size=$(jq -r '.size // empty' <<< "$upload_resp" 2>/dev/null || true)
if [[ -z "$uploaded_size" ]]; then
    SUMMARY="Dropbox upload failed: ${upload_resp:0:200}"
    exit 1
fi
UPLOAD_KB=$(( (uploaded_size + 1023) / 1024 ))
log "Uploaded ${UPLOAD_KB} KB"

# ── 4. keep only the most recent local dump ──────────────────────────────────
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'beedb_*.dump' ! -name "$NAME" -delete
log "Kept only ${NAME} locally"

# ── 5. apply retention on Dropbox ────────────────────────────────────────────
RET_KEPT=0; RET_DEL=0; RET_SKIP=0

apply_retention() {
    local resp cursor has_more
    resp=$(curl -s -X POST https://api.dropboxapi.com/2/files/list_folder \
        --header "Authorization: Bearer ${TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{\"path\": \"${DROPBOX_FOLDER}\", \"recursive\": false}" || true)

    if ! jq -e '.entries' <<< "$resp" >/dev/null 2>&1; then
        log "list_folder failed: ${resp:0:200}"
        return 1
    fi

    local -a files=()
    while true; do
        while IFS=$'\t' read -r name path; do
            [[ -z "$name" ]] && continue
            files+=("${name}"$'\t'"${path}")
        done < <(jq -r '.entries[] | select(.[".tag"]=="file") | [.name, .path_lower] | @tsv' <<< "$resp")

        has_more=$(jq -r '.has_more // false' <<< "$resp")
        [[ "$has_more" != "true" ]] && break
        cursor=$(jq -r '.cursor' <<< "$resp")
        resp=$(curl -s -X POST https://api.dropboxapi.com/2/files/list_folder/continue \
            --header "Authorization: Bearer ${TOKEN}" \
            --header "Content-Type: application/json" \
            --data "{\"cursor\": \"${cursor}\"}" || true)
        if ! jq -e '.entries' <<< "$resp" >/dev/null 2>&1; then
            log "list_folder/continue failed: ${resp:0:200}"
            return 1
        fi
    done

    local now_epoch entry name path d iso file_epoch dow dom_str dom age_days keep
    now_epoch=$(date +%s)

    for entry in "${files[@]}"; do
        name=${entry%%$'\t'*}
        path=${entry#*$'\t'}

        if [[ ! "$name" =~ ^beedb_([0-9]{8})T[0-9]{6}\.dump$ ]]; then
            log "Skipping unrecognised file: $name"
            RET_SKIP=$((RET_SKIP + 1))
            continue
        fi

        d=${BASH_REMATCH[1]}
        iso="${d:0:4}-${d:4:2}-${d:6:2}"
        file_epoch=$(date -d "$iso" +%s)
        dow=$(date -d "$iso" +%u)          # 1=Mon..7=Sun
        dom_str=$(date -d "$iso" +%d)
        dom=$((10#$dom_str))               # force base 10
        age_days=$(( (now_epoch - file_epoch) / 86400 ))

        keep=false
        if   (( age_days <= 14 )); then
            keep=true
        elif (( age_days <= 60 )) && [[ "$dow" == "1" ]]; then
            keep=true
        elif (( age_days <= 365 )) && [[ "$dow" == "1" ]] && (( dom <= 7 )); then
            keep=true
        fi

        if $keep; then
            RET_KEPT=$((RET_KEPT + 1))
        else
            local del_resp
            del_resp=$(curl -s -X POST https://api.dropboxapi.com/2/files/delete_v2 \
                --header "Authorization: Bearer ${TOKEN}" \
                --header "Content-Type: application/json" \
                --data "{\"path\": \"${path}\"}" || true)
            if jq -e '.metadata' <<< "$del_resp" >/dev/null 2>&1; then
                log "Deleted ${path} (age ${age_days}d)"
                RET_DEL=$((RET_DEL + 1))
            else
                log "Delete failed for ${path}: ${del_resp:0:200}"
                RET_SKIP=$((RET_SKIP + 1))
            fi
        fi
    done

    return 0
}

if apply_retention; then
    log "Retention: kept ${RET_KEPT}, deleted ${RET_DEL}, skipped ${RET_SKIP}"
else
    log "Retention step encountered errors"
fi

STATUS="OK"
SUMMARY="${UPLOAD_KB} KB uploaded; retention kept ${RET_KEPT}, deleted ${RET_DEL}"
log "Done: ${SUMMARY}"
