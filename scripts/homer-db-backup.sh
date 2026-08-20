#!/usr/bin/env bash
# =============================================================================
# homer-db-backup.sh — sanitized portfolio edition
# Online PostgreSQL base backup with fail-fast tooling checks, immediate
# pg_verifybackup validation and retention only after the new backup is proven.
# =============================================================================

set -u

BACKUP_ROOT="${HOMER_BACKUP_ROOT:-/srv/example/backups/postgresql/base}"
VERIFY_STATE="${HOMER_VERIFY_STATE:-/var/lib/sip-homer-toolkit/backup-verify-state}"
LOG_FILE="${HOMER_BACKUP_LOG:-/var/log/sip-homer-toolkit/db-backup.log}"
DB_OS_USER="${HOMER_DB_OS_USER:-postgres}"
KEEP_BACKUPS="${HOMER_KEEP_BACKUPS:-1}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
NEW_BACKUP="${BACKUP_ROOT}/backup_${STAMP}"

prepare_log() {
    mkdir -p "$(dirname "$LOG_FILE")" || return 1
    touch "$LOG_FILE" || return 1
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

resolve_pg_tool() {
    local tool="$1" candidate version
    candidate="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$candidate" ] && { printf '%s' "$candidate"; return 0; }

    for version in 17 16 15 14 13; do
        candidate="/usr/lib/postgresql/${version}/bin/${tool}"
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

fail() {
    log "[FATAL] $*"
    exit 1
}

main() {
    local pg_basebackup pg_verifybackup size_kb verify_id old

    prepare_log || { echo "Unable to initialize backup log." >&2; exit 1; }
    mkdir -p "$BACKUP_ROOT" "$(dirname "$VERIFY_STATE")" || fail "Unable to prepare backup directories."

    log "============================================================"
    log "Starting online PostgreSQL base backup -> ${NEW_BACKUP}"

    pg_basebackup="$(resolve_pg_tool pg_basebackup)" || fail "pg_basebackup is unavailable; no backup was started."
    pg_verifybackup="$(resolve_pg_tool pg_verifybackup)" || fail "pg_verifybackup is unavailable; no backup was started."

    command -v sudo >/dev/null || fail "sudo is required to switch to the database OS account."
    id "$DB_OS_USER" >/dev/null 2>&1 || fail "Database OS account does not exist: ${DB_OS_USER}"

    if [ -e "$NEW_BACKUP" ]; then
        fail "Target already exists unexpectedly: ${NEW_BACKUP}"
    fi

    log "[INFO] Running pg_basebackup online; database service remains available."
    if sudo -u "$DB_OS_USER" "$pg_basebackup" \
        -D "$NEW_BACKUP" \
        -F p \
        -X stream \
        -c fast \
        -P >> "$LOG_FILE" 2>&1; then
        size_kb="$(du -sk "$NEW_BACKUP" | awk '{print $1}')"
        log "[OK] pg_basebackup completed. Approx size: ${size_kb} KiB"
    else
        log "[FATAL] pg_basebackup failed. Previous retained backups are untouched."
        rm -rf -- "$NEW_BACKUP"
        exit 1
    fi

    log "[INFO] Running pg_verifybackup before retention rotation..."
    if sudo -u "$DB_OS_USER" "$pg_verifybackup" "$NEW_BACKUP" >> "$LOG_FILE" 2>&1; then
        log "[OK] pg_verifybackup passed — new backup is structurally valid."
    else
        log "[FATAL] pg_verifybackup failed. New backup rejected; old retained backup preserved."
        rm -rf -- "$NEW_BACKUP"
        exit 1
    fi

    verify_id="$(basename "$NEW_BACKUP" | sed 's/^backup_//')"
    cat > "$VERIFY_STATE" <<EOF
BACKUP_ID=${verify_id}
STATUS=PENDING
LAST_CHECKED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 0640 "$VERIFY_STATE" 2>/dev/null || true
    log "[INFO] Deep-verify state reset to PENDING for backup ${verify_id}."

    log "[INFO] Applying retention only after the new backup passed validation."
    while [ "$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'backup_*' | wc -l)" -gt "$KEEP_BACKUPS" ]; do
        old="$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'backup_*' -printf '%T@|%p\n' | sort -n | head -1 | cut -d'|' -f2-)"
        [ -n "$old" ] || break
        [ "$old" != "$NEW_BACKUP" ] || break
        log "[INFO] Removing superseded verified backup: $(basename "$old")"
        rm -rf -- "$old" || fail "Retention removal failed for ${old}."
    done

    log "[OK] Backup run complete."
    log "============================================================"
}

main "$@"
