#!/bin/bash
# =============================================================================
# homer-db-backup-deep-verify.sh
#
# Real restore test of the current base backup -- not just checksum
# validation (that already happens immediately in homer-db-backup.sh via
# pg_verifybackup). This script actually:
#   1. Copies the current backup to a disposable scratch directory
#   2. Spins up a temporary, throwaway PostgreSQL instance from that copy
#      on an alternate port, replaying WAL via restore_command
#   3. Waits for it to reach a consistent, queryable state
#   4. Runs a real query against it to confirm data is genuinely readable
#   5. Shuts the scratch instance down and DELETES the scratch copy
#      entirely, regardless of outcome (trap-guarded cleanup)
#   6. Records PASS/FAIL in the shared state file that homer-sanity-check.sh
#      alarms on
#
# This is intentionally NOT run on the same schedule as the backup itself --
# it's I/O-heavy and can reasonably take hours for a large database, so it
# should run on its own cron entry roughly a day later (e.g. backup Sunday
# 03:00 -> this Monday 03:00), never overlapping with the backup job.
#
# The scratch instance is deliberately minimal (small shared_buffers,
# archiving disabled) since it only needs to start and answer one query,
# not serve real traffic.
#
# Logs to /var/log/homer/homer-db-backup-deep-verify.log
# =============================================================================

DATA_MOUNT_CONFIG="/etc/homer/data-mount.conf"
DATA_MOUNT_DEFAULT="/data"
[ -f "$DATA_MOUNT_CONFIG" ] && source "$DATA_MOUNT_CONFIG"
if [ -z "$DATA_MOUNT" ]; then
    DATA_MOUNT="$DATA_MOUNT_DEFAULT"
fi

BASE_BACKUP_DIR="${DATA_MOUNT}/homer_backup/sip_homer_db_backup/base"
WAL_ARCHIVE_DIR="${DATA_MOUNT}/homer_backup/sip_homer_db_backup/wal"
SCRATCH_ROOT="${DATA_MOUNT}/homer_backup/verify_scratch"
VERIFY_STATE_FILE="/etc/homer/.backup_verify_state"
DB_USER="postgres"
SCRATCH_PORT=5433
STARTUP_TIMEOUT_SEC=21600   # 6 hours -- generous, this can legitimately take a while
LOG_FILE="/var/log/homer/homer-db-backup-deep-verify.log"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 666 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}
separator() { log "============================================================"; }

# --- Resolve PostgreSQL binaries robustly -------------------------------------
# pg_ctl (like pg_verifybackup) is NOT symlinked onto PATH by Ubuntu's
# postgresql-common packaging -- discovered during initial rollout when
# homer-db-backup.sh hit this exact gap with pg_verifybackup. Checking this
# BEFORE the expensive backup-copy step, so a missing-tool problem fails
# fast/cheap instead of after copying 150GB+ for nothing.
resolve_pg_tool() {
    local tool="$1" candidate
    candidate=$(command -v "$tool" 2>/dev/null)
    if [ -n "$candidate" ]; then
        echo "$candidate"
        return 0
    fi
    for v in 16 15 14 13 17; do
        if [ -x "/usr/lib/postgresql/${v}/bin/${tool}" ]; then
            echo "/usr/lib/postgresql/${v}/bin/${tool}"
            return 0
        fi
    done
    return 1
}

write_state() {
    local backup_id="$1" status="$2"
    {
        echo "BACKUP_ID=${backup_id}"
        echo "STATUS=${status}"
        echo "LAST_CHECKED=\"$(date '+%Y-%m-%d %H:%M:%S')\""
    } | sudo tee "$VERIFY_STATE_FILE" > /dev/null
    sudo chmod 666 "$VERIFY_STATE_FILE" 2>/dev/null
}

SCRATCH_DIR=""
cleanup() {
    if [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
        log "Cleanup: stopping scratch instance (if running) and deleting scratch copy..."
        sudo -u "$DB_USER" "$PG_CTL_BIN" -D "$SCRATCH_DIR" -m fast stop >> "$LOG_FILE" 2>&1
        rm -rf "$SCRATCH_DIR"
        log "Scratch directory removed: ${SCRATCH_DIR}"
    fi
}
trap cleanup EXIT

separator
log "Starting deep backup verification (real restore test)"

if ! mountpoint -q "$DATA_MOUNT"; then
    log "[FATAL] ${DATA_MOUNT} is NOT mounted. Aborting -- cannot verify."
    exit 1
fi

PG_CTL_BIN=$(resolve_pg_tool pg_ctl)
PSQL_BIN=$(resolve_pg_tool psql)
MISSING_TOOLS=""
[ -z "$PG_CTL_BIN" ] && MISSING_TOOLS="${MISSING_TOOLS}pg_ctl "
[ -z "$PSQL_BIN" ] && MISSING_TOOLS="${MISSING_TOOLS}psql "
if [ -n "$MISSING_TOOLS" ]; then
    log "[FATAL] Required tool(s) not found on PATH or in any known /usr/lib/postgresql/*/bin/ location: ${MISSING_TOOLS}"
    log "[FATAL] Aborting BEFORE copying the backup -- no point doing an hours-long copy we can't act on."
    log "[FATAL] Contact an admin to confirm the correct PostgreSQL version/install path on this VM."
    exit 1
fi
log "Using pg_ctl at: ${PG_CTL_BIN}, psql at: ${PSQL_BIN}"

CURRENT_BACKUP=$(ls -1d "${BASE_BACKUP_DIR}"/backup_* 2>/dev/null | sort | tail -1)
if [ -z "$CURRENT_BACKUP" ]; then
    log "[FATAL] No base backup found in ${BASE_BACKUP_DIR}. Nothing to verify."
    exit 1
fi

BACKUP_ID=$(basename "$CURRENT_BACKUP" | sed 's/^backup_//')
log "Verifying backup: ${CURRENT_BACKUP} (ID: ${BACKUP_ID})"

# --- Copy the backup to a disposable scratch location ------------------------
mkdir -p "$SCRATCH_ROOT"
chmod 777 "$SCRATCH_ROOT" 2>/dev/null
SCRATCH_DIR="${SCRATCH_ROOT}/restore_${BACKUP_ID}_$(date +%s)"

log "Copying backup to scratch location: ${SCRATCH_DIR} (this is the slow part -- expect this to take a while for a large database)"
COPY_START=$(date +%s)
sudo -u "$DB_USER" cp -a "$CURRENT_BACKUP" "$SCRATCH_DIR" >> "$LOG_FILE" 2>&1
COPY_EXIT=$?
COPY_ELAPSED=$(( $(date +%s) - COPY_START ))

if [ $COPY_EXIT -ne 0 ]; then
    log "[FATAL] Copy to scratch location failed (exit ${COPY_EXIT}, ${COPY_ELAPSED}s elapsed)."
    write_state "$BACKUP_ID" "FAIL"
    exit 1
fi
log "[OK] Copy completed in ${COPY_ELAPSED}s."

# --- Configure the scratch instance for recovery ------------------------------
# IMPORTANT: Ubuntu/Debian's PostgreSQL packaging keeps postgresql.conf and
# pg_hba.conf OUTSIDE the data directory (in /etc/postgresql/16/main/), so
# pg_basebackup never includes them -- the copied scratch directory has no
# config files at all. We do NOT copy the live server's actual config file
# verbatim: Debian's version typically contains absolute paths back to the
# real cluster (data_directory, hba_file, external_pid_file, etc.), and
# copying it as-is risks the scratch instance quietly referencing parts of
# the LIVE cluster's real files. Instead we write a clean, minimal,
# self-contained config that only ever references its own scratch directory.
sudo -u "$DB_USER" touch "${SCRATCH_DIR}/recovery.signal"

cat > /tmp/deep-verify-postgresql.conf.$$ << CONF_EOF
port = ${SCRATCH_PORT}
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
shared_buffers = 128MB
archive_mode = off
shared_preload_libraries = 'timescaledb'
restore_command = 'cp ${WAL_ARCHIVE_DIR}/%f %p'

# These MUST be >= the live primary's values at the time the WAL being
# replayed was generated, or PostgreSQL aborts recovery with
# "insufficient parameter settings" during initial rollout.
# Matched exactly to the live server's current values (checked via
# pg_settings) rather than guessed, since exceeding them unnecessarily
# just costs more memory for no benefit on a throwaway instance.
max_connections = 100
max_worker_processes = 23
max_prepared_transactions = 0
max_locks_per_transaction = 256
max_wal_senders = 10
CONF_EOF
sudo -u "$DB_USER" cp /tmp/deep-verify-postgresql.conf.$$ "${SCRATCH_DIR}/postgresql.conf"
rm -f /tmp/deep-verify-postgresql.conf.$$

# Minimal, permissive, local-only auth -- this instance is isolated by port
# and socket path, destroyed immediately after the test, and never reachable
# beyond localhost, so trust auth here is acceptable for a throwaway check.
cat > /tmp/deep-verify-pg_hba.conf.$$ << 'HBA_EOF'
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
HBA_EOF
sudo -u "$DB_USER" cp /tmp/deep-verify-pg_hba.conf.$$ "${SCRATCH_DIR}/pg_hba.conf"
rm -f /tmp/deep-verify-pg_hba.conf.$$

# Empty is fine -- we only use trust auth (no ident maps needed), this just
# quiets a harmless "file not found" log line during startup.
sudo -u "$DB_USER" touch "${SCRATCH_DIR}/pg_ident.conf"

# --- Start the scratch instance --------------------------------------------
log "Starting scratch PostgreSQL instance on port ${SCRATCH_PORT}..."
sudo -u "$DB_USER" "$PG_CTL_BIN" -D "$SCRATCH_DIR" -l "${SCRATCH_DIR}/scratch_startup.log" start >> "$LOG_FILE" 2>&1
START_EXIT=$?

# Check pg_ctl's own exit code IMMEDIATELY -- do not blindly poll for up to
# 6 hours if it already told us plainly that startup failed.
if [ $START_EXIT -ne 0 ]; then
    log "[FATAL] pg_ctl reported startup failure (exit ${START_EXIT}) -- not waiting further."
    log "Startup log:"
    cat "${SCRATCH_DIR}/scratch_startup.log" >> "$LOG_FILE" 2>/dev/null
    write_state "$BACKUP_ID" "FAIL"
    exit 1
fi

# --- Wait for recovery to FULLY complete (not just "accepting connections") -
# pg_isready only checks that the port/socket accepts TCP connections -- but
# Postgres can accept read-only connections WHILE STILL ACTIVELY REPLAYING
# WAL (standard "hot standby" behavior). During rollout, running
# our validation query during that window got cancelled with "canceling
# statement due to conflict with recovery" -- a normal, documented Postgres
# behavior when replay needs to clean up a row version a concurrent query is
# reading, NOT a sign the backup is bad. The correct readiness signal is
# pg_is_in_recovery() returning false, meaning replay has caught up to the
# end of available WAL and the instance has auto-promoted to a fully
# consistent, no-longer-replaying state (this cluster used recovery.signal,
# not standby.signal, so it promotes automatically once WAL runs out rather
# than waiting indefinitely for more).
WAITED=0
READY=0
while [ "$WAITED" -lt "$STARTUP_TIMEOUT_SEC" ]; do
    IN_RECOVERY=$(sudo -u "$DB_USER" "$PSQL_BIN" -h 127.0.0.1 -p "$SCRATCH_PORT" -d homer_data -t -A -c "SELECT pg_is_in_recovery();" 2>/dev/null)
    if [ "$IN_RECOVERY" = "f" ]; then
        READY=1
        break
    fi
    # If the postmaster process has died entirely, don't keep waiting either.
    if ! sudo -u "$DB_USER" "$PG_CTL_BIN" -D "$SCRATCH_DIR" status >/dev/null 2>&1; then
        log "[FATAL] Scratch instance process is no longer running -- it exited during recovery."
        log "Startup log:"
        cat "${SCRATCH_DIR}/scratch_startup.log" >> "$LOG_FILE" 2>/dev/null
        write_state "$BACKUP_ID" "FAIL"
        exit 1
    fi
    sleep 30
    WAITED=$((WAITED + 30))
    if [ $((WAITED % 600)) -eq 0 ]; then
        log "Still waiting for recovery to fully complete (still replaying WAL or not yet connectable)... (${WAITED}s elapsed)"
    fi
done

if [ "$READY" -ne 1 ]; then
    log "[FATAL] Scratch instance did not finish recovery within ${STARTUP_TIMEOUT_SEC}s."
    log "Startup log tail:"
    tail -30 "${SCRATCH_DIR}/scratch_startup.log" >> "$LOG_FILE" 2>/dev/null
    write_state "$BACKUP_ID" "FAIL"
    exit 1
fi
log "[OK] Recovery fully complete -- instance has promoted out of recovery mode."

log "[OK] Scratch instance is up and accepting connections after ${WAITED}s."

# --- Run a real validation query ----------------------------------------------
QUERY_RESULT=$(sudo -u "$DB_USER" "$PSQL_BIN" -h 127.0.0.1 -p "$SCRATCH_PORT" -d homer_data -t -A -c \
    "SELECT COUNT(*), MAX(create_date) FROM hep_proto_1_call;" 2>&1)
QUERY_EXIT=$?

if [ $QUERY_EXIT -ne 0 ] || [ -z "$QUERY_RESULT" ]; then
    log "[FATAL] Validation query failed against the restored instance: ${QUERY_RESULT}"
    write_state "$BACKUP_ID" "FAIL"
    exit 1
fi

log "[OK] Validation query succeeded. Result: ${QUERY_RESULT}"
log "[PASS] Backup ${BACKUP_ID} is a genuinely restorable, queryable backup."
write_state "$BACKUP_ID" "PASS"

separator
log "Deep verification complete -- PASS."
log ""

exit 0
