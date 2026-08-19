#!/usr/bin/env bash
# Dump every user database, upload each to Dropbox, apply retention, mail the
# result. Meant to run daily from cron on the Docker host.
#
# Databases are auto-discovered from the running Docker postgres (all where
# datallowconn AND NOT datistemplate). Each dump is named
# `<dbname>_YYYYMMDDTHHMMSS.dump`.
#
# Retention on Dropbox (per file, based on the timestamp):
#   - every backup for the last 14 days (daily)
#   - the Monday backup for the last 60 days (weekly)
#   - the first-Monday-of-month backup for the last 365 days (monthly)
# Local: only the most recent dump of each database is kept in ./backups/.

set -eo pipefail

# cron gives a minimal PATH; make sure docker, jq, ssmtp are reachable.
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

: "${POSTGRES_USER:=postgres}"
: "${DROPBOX_APP_KEY:?DROPBOX_APP_KEY missing in .env}"
: "${DROPBOX_APP_SECRET:?DROPBOX_APP_SECRET missing in .env}"
: "${DROPBOX_REFRESH_TOKEN:?DROPBOX_REFRESH_TOKEN missing in .env}"
: "${DROPBOX_FOLDER:=/beedb-backups}"
: "${BACKUP_MAIL_FROM:=}"
: "${BACKUP_MAIL_TO:=}"

BACKUP_DIR="$(pwd)/backups"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%dT%H%M%S)

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
    if (( ec != 0 )) && [[ "$STATUS" == OK* ]]; then
        STATUS="FAILED"
    fi
    # The failure paths only set SUMMARY before exiting, so log the reason here
    # as well — otherwise it exists solely in the mail subject and the log ends
    # mid-step with no explanation.
    [[ "$STATUS" != OK* ]] && log "FAILED: ${SUMMARY}"
    send_mail "beedb backup | ${STATUS} | ${SUMMARY}"
}
trap on_exit EXIT

# ── 1. discover databases ────────────────────────────────────────────────────
log "Discovering user databases"
mapfile -t DATABASES < <(docker compose exec -T db \
    psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY datname")

if (( ${#DATABASES[@]} == 0 )); then
    SUMMARY="no user databases found"
    exit 1
fi
log "Databases: ${DATABASES[*]}"

# ── 2. dump each database, keeping exactly one local dump per database ───────
# The older dump of a database is removed only once its replacement exists and
# is non-empty, so ./backups/ never accumulates and never runs empty either.
# This happens here rather than after the upload on purpose: an unreachable or
# full Dropbox must not cause local dumps to pile up on the host.
declare -A DUMP_KB
declare -a DUMP_NAMES
for DB in "${DATABASES[@]}"; do
    NAME="${DB}_${TIMESTAMP}.dump"
    OUTFILE="${BACKUP_DIR}/${NAME}"
    log "Dumping ${DB} to ${OUTFILE}"
    docker compose exec -T db pg_dump -U "$POSTGRES_USER" -Fc "$DB" > "$OUTFILE"
    if [[ ! -s "$OUTFILE" ]]; then
        SUMMARY="pg_dump produced an empty file for ${DB}"
        exit 1
    fi
    bytes=$(stat -c%s "$OUTFILE")
    DUMP_KB[$DB]=$(( (bytes + 1023) / 1024 ))
    DUMP_NAMES+=("$NAME")
    log "  ${DB}: ${DUMP_KB[$DB]} KB"

    # Drop this database's previous dumps. The -name glob confines it to the
    # database just dumped, the -regex to the generated timestamp pattern, so
    # hand-placed files and other databases' dumps are never touched.
    find "$BACKUP_DIR" -maxdepth 1 -type f \
        -name "${DB}_*.dump" \
        -regextype posix-extended -regex ".*_[0-9]{8}T[0-9]{6}\.dump$" \
        ! -name "$NAME" -delete
done

# ── 3. Dropbox access token ──────────────────────────────────────────────────
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

# ── 4. apply retention on Dropbox ────────────────────────────────────────────
# Deliberately before the upload: expiring old backups is what frees space, so
# a full Dropbox unblocks itself on the next run. With the upload first, a
# failing upload skips retention, which keeps the destination full, which keeps
# the upload failing — the account never recovers without manual work.
# Safe in this order because retention never deletes anything younger than 15
# days, so even a long run of failed uploads cannot remove a recent backup.
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

        # Match <dbname>_YYYYMMDDTHHMMSS.dump for any dbname; retention uses
        # the timestamp only, so all databases share the same schedule.
        if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*_([0-9]{8})T[0-9]{6}\.dump$ ]]; then
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

# A broken retention step must not stop the upload — getting today's dumps off
# the host matters more than pruning old ones — but it must not be reported as
# a clean run either, or the folder grows unnoticed for months.
RETENTION_OK=true
if apply_retention; then
    log "Retention: kept ${RET_KEPT}, deleted ${RET_DEL}, skipped ${RET_SKIP}"
else
    RETENTION_OK=false
    log "Retention step encountered errors"
fi

# ── 5. upload each dump ──────────────────────────────────────────────────────
# Single-request upload; Dropbox limit is 150 MB per file. If any dump ever
# grows past that, switch to /2/files/upload_session/*.
TOTAL_UP_KB=0
for NAME in "${DUMP_NAMES[@]}"; do
    log "Uploading ${NAME} to ${DROPBOX_FOLDER}"
    upload_resp=$(curl -s --max-time 3600 -X POST \
        https://content.dropboxapi.com/2/files/upload \
        --header "Authorization: Bearer ${TOKEN}" \
        --header "Dropbox-API-Arg: {\"path\": \"${DROPBOX_FOLDER}/${NAME}\",\"mode\": \"overwrite\",\"mute\": true}" \
        --header "Content-Type: application/octet-stream" \
        --data-binary "@${BACKUP_DIR}/${NAME}" || true)
    uploaded_size=$(jq -r '.size // empty' <<< "$upload_resp" 2>/dev/null || true)
    if [[ -z "$uploaded_size" ]]; then
        SUMMARY="Dropbox upload failed for ${NAME}: ${upload_resp:0:200}"
        exit 1
    fi
    up_kb=$(( (uploaded_size + 1023) / 1024 ))
    TOTAL_UP_KB=$(( TOTAL_UP_KB + up_kb ))
    log "  Uploaded ${up_kb} KB"
done

if $RETENTION_OK; then
    STATUS="OK"
else
    STATUS="OK (retention failed)"
fi
per_db=""
for DB in "${DATABASES[@]}"; do
    per_db+="${DB}=${DUMP_KB[$DB]}KB "
done
SUMMARY="${#DATABASES[@]} DBs (${TOTAL_UP_KB} KB): ${per_db% }; retention kept ${RET_KEPT}, deleted ${RET_DEL}"
log "Done: ${SUMMARY}"
