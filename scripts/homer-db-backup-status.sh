#!/usr/bin/env bash
# =============================================================================
# homer-db-backup-status.sh — sanitized portfolio edition
# Lightweight read-only status reporter for a weekly PostgreSQL base backup.
# It deliberately does not start a backup, restore, checksum scan or DB query.
# =============================================================================

set -u

BACKUP_ROOT="${HOMER_BACKUP_ROOT:-/srv/example/backups/postgresql/base}"
VERIFY_STATE="${HOMER_VERIFY_STATE:-/var/lib/sip-homer-toolkit/backup-verify-state}"
LOG_FILE="${HOMER_BACKUP_LOG:-/var/log/sip-homer-toolkit/db-backup.log}"
EXPECTED_WEEKDAY="${HOMER_BACKUP_WEEKDAY:-Sunday}"
EXPECTED_TIME="${HOMER_BACKUP_TIME:-03:15}"
WARN_AFTER_DAYS="${HOMER_BACKUP_WARN_AFTER_DAYS:-8}"
ERROR_AFTER_DAYS="${HOMER_BACKUP_ERROR_AFTER_DAYS:-10}"

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

prepare_log() {
    mkdir -p "$(dirname "$LOG_FILE")" || return 1
    touch "$LOG_FILE" || return 1
}

latest_backup() {
    find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'backup_*' \
        -printf '%T@|%p\n' 2>/dev/null | sort -nr | head -1
}

state_value() {
    local key="$1"
    [ -r "$VERIFY_STATE" ] || return 0
    awk -F '=' -v k="$key" '$1==k {sub(/^[^=]*=/,""); gsub(/^"|"$/,""); print; exit}' "$VERIFY_STATE"
}

main() {
    local latest stamp path epoch now age_days backup_id verify_id verify_status checked final="HEALTHY" rc=0

    prepare_log || { echo "Unable to open status log: $LOG_FILE" >&2; exit 2; }

    log STATUS "============================================================"
    log STATUS "Daily DB backup health report"
    log STATUS "Expected schedule: ${EXPECTED_WEEKDAY} ${EXPECTED_TIME}"

    latest="$(latest_backup)"
    if [ -z "$latest" ]; then
        log ERROR "No retained base backup directory was found under ${BACKUP_ROOT}."
        log ERROR "Backup status: UNHEALTHY"
        exit 2
    fi

    stamp="${latest%%|*}"
    path="${latest#*|}"
    epoch="${stamp%.*}"
    now="$(date +%s)"
    age_days=$(( (now - epoch) / 86400 ))
    backup_id="$(basename "$path" | sed 's/^backup_//')"

    log STATUS "Latest backup: $(basename "$path")"
    log STATUS "Backup path: $path"
    log STATUS "Backup timestamp: $(date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S')"
    log STATUS "Backup age: ${age_days} day(s)"

    if [ "$age_days" -gt "$ERROR_AFTER_DAYS" ]; then
        log ERROR "Backup is stale beyond the configured error threshold (${ERROR_AFTER_DAYS} days)."
        final="UNHEALTHY"; rc=2
    elif [ "$age_days" -gt "$WARN_AFTER_DAYS" ]; then
        log WARN "Backup is older than the expected weekly tolerance (${WARN_AFTER_DAYS} days)."
        final="WARNING"; rc=1
    else
        log OK "Backup age is within the weekly schedule tolerance."
    fi

    verify_id="$(state_value BACKUP_ID)"
    verify_status="$(state_value STATUS)"
    checked="$(state_value LAST_CHECKED)"

    if [ -z "$verify_status" ]; then
        log WARN "Deep-verification state is unavailable."
        [ "$final" = "HEALTHY" ] && { final="WARNING"; rc=1; }
    elif [ "$verify_id" != "$backup_id" ]; then
        log WARN "Deep-verification state refers to a different backup (${verify_id:-unknown})."
        [ "$final" = "HEALTHY" ] && { final="WARNING"; rc=1; }
    elif [ "$verify_status" = "PASS" ]; then
        log OK "Deep verification: PASS (${checked:-timestamp unavailable})"
    elif [ "$verify_status" = "PENDING" ]; then
        log WARN "Deep verification: PENDING"
        [ "$final" = "HEALTHY" ] && { final="WARNING"; rc=1; }
    else
        log ERROR "Deep verification: ${verify_status}"
        final="UNHEALTHY"; rc=2
    fi

    log "$([ "$final" = HEALTHY ] && echo OK || { [ "$final" = WARNING ] && echo WARN || echo ERROR; })" "Backup status: ${final}"
    log STATUS "============================================================"
    echo >> "$LOG_FILE"
    exit "$rc"
}

main "$@"
