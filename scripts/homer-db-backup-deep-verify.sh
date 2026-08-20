#!/bin/bash
# =============================================================================
# homer-db-backup-deep-verify.sh — sanitized portfolio edition
#
# A checksum-valid backup is not automatically a restorable backup. This
# workflow proves restorability by starting a disposable PostgreSQL instance
# from the latest retained base backup, replaying archived WAL, waiting until
# recovery is truly complete, running a real validation query, and destroying
# the scratch environment regardless of outcome.
#
# All paths/database names are fictionalized for the public repository.
# =============================================================================

set -u

BACKUP_ROOT="${BACKUP_ROOT:-/srv/example/backups/postgres/base}"
WAL_ARCHIVE="${WAL_ARCHIVE:-/srv/example/backups/postgres/wal}"
SCRATCH_ROOT="${SCRATCH_ROOT:-/srv/example/backups/restore-scratch}"
STATE_FILE="${STATE_FILE:-/var/lib/sip-homer-toolkit/backup-verify.state}"
LOG_FILE="${LOG_FILE:-/var/log/sip-homer-toolkit/db-backup-deep-verify.log}"
DB_USER="${DB_USER:-postgres}"
VALIDATION_DB="${VALIDATION_DB:-sip_capture}"
VALIDATION_TABLE="${VALIDATION_TABLE:-hep_proto_1_call}"
SCRATCH_PORT="${SCRATCH_PORT:-55433}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-21600}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
touch "$LOG_FILE"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

resolve_pg_tool() {
    local tool="$1" path version
    path=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    for version in 18 17 16 15 14; do
        path="/usr/lib/postgresql/${version}/bin/${tool}"
        [ -x "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

write_state() {
    local id="$1" status="$2"
    umask 027
    cat > "$STATE_FILE" <<EOF
BACKUP_ID=${id}
STATUS=${status}
LAST_CHECKED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

PG_CTL=$(resolve_pg_tool pg_ctl) || { log "[FATAL] pg_ctl not found; failing before expensive copy."; exit 1; }
PSQL=$(resolve_pg_tool psql) || { log "[FATAL] psql not found; failing before expensive copy."; exit 1; }

LATEST=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'backup_*' -printf '%f|%p\n' 2>/dev/null | sort | tail -1)
[ -n "$LATEST" ] || { log "[FATAL] No retained base backup found under ${BACKUP_ROOT}."; exit 1; }
BACKUP_ID=${LATEST%%|*}
BACKUP_ID=${BACKUP_ID#backup_}
BACKUP_PATH=${LATEST#*|}

SCRATCH_DIR=""
cleanup() {
    if [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
        log "Cleanup: stopping and removing disposable restore ${SCRATCH_DIR}."
        sudo -u "$DB_USER" "$PG_CTL" -D "$SCRATCH_DIR" -m immediate stop >> "$LOG_FILE" 2>&1 || true
        rm -rf -- "$SCRATCH_DIR"
    fi
}
trap cleanup EXIT INT TERM

log "============================================================"
log "Starting deep restore verification for backup ${BACKUP_ID}."

mkdir -p "$SCRATCH_ROOT"
SCRATCH_DIR="${SCRATCH_ROOT}/restore_${BACKUP_ID}_$$"
log "Copying retained backup into disposable scratch space."
sudo -u "$DB_USER" cp -a -- "$BACKUP_PATH" "$SCRATCH_DIR" >> "$LOG_FILE" 2>&1 || {
    log "[FAIL] Scratch copy failed."
    write_state "$BACKUP_ID" FAIL
    exit 1
}

# Debian/Ubuntu packages commonly keep primary cluster config outside PGDATA.
# Do not reuse the live configuration: it can contain absolute paths back into
# the real cluster. The scratch instance gets a minimal self-contained config.
touch "${SCRATCH_DIR}/recovery.signal"
cat > "${SCRATCH_DIR}/postgresql.conf" <<EOF
port = ${SCRATCH_PORT}
listen_addresses = '127.0.0.1'
unix_socket_directories = '/tmp'
archive_mode = off
shared_buffers = 128MB
restore_command = 'cp ${WAL_ARCHIVE}/%f %p'
# Recovery-sensitive limits must be at least the values used by the source
# cluster when the replayed WAL was generated. These example values should be
# replaced from pg_settings in a real deployment.
max_connections = 150
max_worker_processes = 32
max_prepared_transactions = 0
max_locks_per_transaction = 256
max_wal_senders = 10
EOF

cat > "${SCRATCH_DIR}/pg_hba.conf" <<'EOF'
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
EOF
touch "${SCRATCH_DIR}/pg_ident.conf"
chown -R "$DB_USER":"$DB_USER" "$SCRATCH_DIR"
chmod 0700 "$SCRATCH_DIR"

log "Starting disposable PostgreSQL on localhost:${SCRATCH_PORT}."
sudo -u "$DB_USER" "$PG_CTL" -D "$SCRATCH_DIR" -l "$SCRATCH_DIR/startup.log" start >> "$LOG_FILE" 2>&1 || {
    log "[FAIL] Scratch PostgreSQL did not start."
    tail -30 "$SCRATCH_DIR/startup.log" >> "$LOG_FILE" 2>/dev/null || true
    write_state "$BACKUP_ID" FAIL
    exit 1
}

# Port readiness is insufficient: PostgreSQL can accept read-only connections
# while WAL replay is still active. Wait for pg_is_in_recovery() = false.
waited=0
ready=0
while [ "$waited" -lt "$STARTUP_TIMEOUT_SEC" ]; do
    state=$(sudo -u "$DB_USER" "$PSQL" -h 127.0.0.1 -p "$SCRATCH_PORT" -d "$VALIDATION_DB" -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || true)
    if [ "$state" = "f" ]; then
        ready=1
        break
    fi
    if ! sudo -u "$DB_USER" "$PG_CTL" -D "$SCRATCH_DIR" status >/dev/null 2>&1; then
        log "[FAIL] Scratch PostgreSQL exited during recovery."
        write_state "$BACKUP_ID" FAIL
        exit 1
    fi
    sleep 30
    waited=$((waited + 30))
done

[ "$ready" -eq 1 ] || {
    log "[FAIL] Recovery did not complete before timeout."
    write_state "$BACKUP_ID" FAIL
    exit 1
}

result=$(sudo -u "$DB_USER" "$PSQL" -h 127.0.0.1 -p "$SCRATCH_PORT" -d "$VALIDATION_DB" -tAc \
    "SELECT COUNT(*), MAX(create_date) FROM ${VALIDATION_TABLE};" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
    log "[FAIL] Validation query failed: ${result}"
    write_state "$BACKUP_ID" FAIL
    exit 1
fi

log "[OK] Recovery completed and validation query succeeded: ${result}"
log "[PASS] Backup ${BACKUP_ID} is demonstrably restorable and queryable."
write_state "$BACKUP_ID" PASS
log "============================================================"
