#!/bin/bash
# =============================================================================
# homer-db-backup.sh
# Weekly full base backup of the homer_data PostgreSQL cluster via pg_basebackup.
# Runs ONLINE against the live database — no downtime, safe to run while
# heplify-server/homer-app are active.
#
# STORAGE MODEL DESIGN: keeps only the LAST 1 full backup, not
# 2. WAL archiving covers the gap forward from that single backup to now
# (see homer-wal-prune.sh). This roughly halves the backup-side storage
# footprint. The tradeoff: with only 1 backup, there's no older-but-good
# fallback if the latest one is ever silently bad. Two layers of defense
# compensate for this:
#   1. pg_verifybackup runs immediately after every backup (checksum/manifest
#      validation) -- the OLD backup is never deleted until this passes.
#   2. homer-db-backup-deep-verify.sh runs separately (a day later, off the
#      backup's own critical path) and does a REAL restore test -- spins up
#      a temporary throwaway Postgres instance from the backup, confirms it
#      actually starts and serves a query, then tears itself down. Updates
#      a state file that homer-sanity-check.sh alarms on if it ever fails.
#      Taking a fresh manual backup naturally clears any old FAIL alarm,
#      since the alarm is tied to a specific backup's ID, not a persistent
#      flag -- a new backup means a new (unproven-but-not-failed) ID.
#
# Designed to run via cron (suggested: weekly, low-traffic window e.g. Sunday 03:00)
# Logs to /var/log/homer/homer-db-backup.log
# =============================================================================

# --- Backup mount point: shared across all backup scripts, persisted after
# first interactive answer so cron/automation never needs to ask again ------
DATA_MOUNT_CONFIG="/etc/homer/data-mount.conf"
DATA_MOUNT_DEFAULT="/data"
[ -f "$DATA_MOUNT_CONFIG" ] && source "$DATA_MOUNT_CONFIG"
if [ -z "$DATA_MOUNT" ]; then
    if [ -t 0 ]; then
        read -r -p "Enter the backup mount point [${DATA_MOUNT_DEFAULT}]: " DATA_MOUNT_INPUT
        DATA_MOUNT="${DATA_MOUNT_INPUT:-$DATA_MOUNT_DEFAULT}"
        echo "DATA_MOUNT=\"${DATA_MOUNT}\"" > "$DATA_MOUNT_CONFIG" 2>/dev/null
        chmod 644 "$DATA_MOUNT_CONFIG" 2>/dev/null
        echo "Saved backup mount point (${DATA_MOUNT}) to ${DATA_MOUNT_CONFIG} -- future runs (including cron) will use this automatically."
    else
        DATA_MOUNT="$DATA_MOUNT_DEFAULT"
    fi
fi

BACKUP_ROOT="${DATA_MOUNT}/homer_backup/sip_homer_db_backup/base"
DB_USER="postgres"
KEEP_BACKUPS=1
VERIFY_STATE_FILE="/etc/homer/.backup_verify_state"
LOG_FILE="/var/log/homer/homer-db-backup.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
NEW_BACKUP_DIR="${BACKUP_ROOT}/backup_${TIMESTAMP}"

# --- Logging setup (per project convention) ---------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" && chmod 666 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

separator() {
    log "============================================================"
}

# --- Resolve a PostgreSQL binary robustly ------------------------------------
# Some PG tools (psql, pg_basebackup, pg_isready) get symlinked onto PATH by
# Ubuntu's postgresql-common packaging; others (pg_ctl, pg_verifybackup,
# pg_resetwal, pg_rewind) deliberately do NOT and only exist at the versioned
# path. During initial rollout, pg_verifybackup was NOT on PATH even for
# the postgres user, causing a false "[FATAL] backup is corrupt" the first
# time this ran -- it wasn't corrupt, the tool just wasn't found. This
# resolves the real binary location and, critically, distinguishes
# "tool not found" from "verification actually failed" as two entirely
# different failure classes.
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

separator
log "Starting full base backup -> ${NEW_BACKUP_DIR}"

# --- Pre-flight checks --------------------------------------------------------
# Checked BEFORE pg_basebackup runs at all, so a missing-tool problem fails
# fast and cheap instead of discovering it only after a multi-hour transfer.
if ! mountpoint -q "$DATA_MOUNT"; then
    log "[FATAL] ${DATA_MOUNT} is NOT mounted. Aborting backup — no changes made."
    exit 1
fi

if ! sudo systemctl is-active --quiet postgresql; then
    log "[FATAL] PostgreSQL is not active. Aborting backup."
    exit 1
fi

PG_VERIFYBACKUP_BIN=$(resolve_pg_tool pg_verifybackup)
if [ -z "$PG_VERIFYBACKUP_BIN" ]; then
    log "[FATAL] pg_verifybackup not found on PATH or in any known /usr/lib/postgresql/*/bin/ location."
    log "[FATAL] Aborting BEFORE taking the backup -- no point running a multi-hour transfer we can't verify."
    log "[FATAL] Contact an admin to confirm the correct PostgreSQL version/install path on this VM."
    exit 1
fi
log "Using pg_verifybackup at: ${PG_VERIFYBACKUP_BIN}"

mkdir -p "$BACKUP_ROOT"
# NFS root_squash: mkdir -p above also silently creates the "homer_backup"
# and "sip_homer_db_backup" PARENT directories if they didn't already
# exist, as root -- which gets remapped server-side to an anonymous
# identity. The postgres system user (which actually runs pg_basebackup
# below, and which homer-wal-archive.sh also runs as) needs write access
# on every level of this shared tree, not just the leaf "base" directory,
# or it hits the same permission wall one level up.
chmod -R 777 "${DATA_MOUNT}/homer_backup" 2>/dev/null

# --- Run pg_basebackup ---------------------------------------------------------
# -F p   : plain format (directly restorable, not tar)
# -X stream : stream WAL during the backup so it's self-contained / consistent
# -P     : show progress in the log
# -c fast: request an immediate checkpoint rather than waiting (slightly
#          more I/O spike but backup starts immediately, fine for off-peak)
# (backup_manifest is generated by default -- needed for pg_verifybackup below)
sudo -u "$DB_USER" pg_basebackup \
    -D "$NEW_BACKUP_DIR" \
    -F p \
    -X stream \
    -c fast \
    -P \
    >> "$LOG_FILE" 2>&1

BACKUP_EXIT=$?

if [ $BACKUP_EXIT -ne 0 ]; then
    log "[FATAL] pg_basebackup FAILED (exit code ${BACKUP_EXIT}). Removing partial backup directory."
    rm -rf "$NEW_BACKUP_DIR"
    separator
    exit 1
fi

BACKUP_SIZE=$(du -sh "$NEW_BACKUP_DIR" 2>/dev/null | cut -f1)
log "[OK] pg_basebackup completed. Size: ${BACKUP_SIZE}"

# --- Immediate verification: pg_verifybackup ------------------------------------
# Checks the backup's files against its own manifest checksums. This is the
# gate that decides whether we're safe to delete the OLD backup -- if this
# fails, the new (bad) backup is discarded and the old one is left untouched,
# so we're never left with zero valid backups.
log "Running pg_verifybackup (checksum/manifest validation)..."
VERIFY_OUTPUT=$(sudo -u "$DB_USER" "$PG_VERIFYBACKUP_BIN" "$NEW_BACKUP_DIR" 2>&1)
VERIFY_EXIT=$?

if [ $VERIFY_EXIT -ne 0 ]; then
    log "[FATAL] pg_verifybackup FAILED on the new backup:"
    log "$VERIFY_OUTPUT"
    if echo "$VERIFY_OUTPUT" | grep -qi "command not found\|No such file"; then
        log "[FATAL] This looks like a MISSING TOOL problem, not actual corruption -- but treating it as"
        log "[FATAL] unverified either way, since we genuinely don't know the backup's real state. Discarding"
        log "[FATAL] this backup and keeping the existing one untouched. Contact an admin to fix the"
        log "[FATAL] pg_verifybackup path issue before the next scheduled run."
    else
        log "[FATAL] The new backup appears CORRUPT. Discarding it and keeping the existing backup untouched."
    fi
    rm -rf "$NEW_BACKUP_DIR"
    separator
    log "Backup run FAILED verification -- old backup preserved, no rotation performed."
    log ""
    exit 1
fi

log "[OK] pg_verifybackup passed -- backup is structurally valid."

# --- Reset the deep-verify state for this NEW backup ----------------------------
# This is what "clears the alarm": if the PREVIOUS backup's deep-verify had
# failed, that FAIL was tied to the OLD backup's ID. This new backup gets a
# fresh PENDING state under its own ID -- homer-db-backup-deep-verify.sh will
# update it to PASS/FAIL once it actually runs (typically the next day).
{
    echo "BACKUP_ID=${TIMESTAMP}"
    echo "STATUS=PENDING"
    echo "LAST_CHECKED=\"$(date '+%Y-%m-%d %H:%M:%S')\""
} | sudo tee "$VERIFY_STATE_FILE" > /dev/null
sudo chmod 666 "$VERIFY_STATE_FILE" 2>/dev/null
log "Deep-verify state reset to PENDING for backup ${TIMESTAMP} (homer-db-backup-deep-verify.sh will update this)."

# --- Rotation: keep only the last N backups -------------------------------------
# Only runs AFTER the new backup is confirmed good (exit code + pg_verifybackup),
# so we never drop below 1 valid backup even if something goes wrong mid-rotation.
log "Rotating old backups (keeping last ${KEEP_BACKUPS})..."

mapfile -t ALL_BACKUPS < <(ls -1dt "${BACKUP_ROOT}"/backup_* 2>/dev/null)
TOTAL_BACKUPS=${#ALL_BACKUPS[@]}

if [ "$TOTAL_BACKUPS" -gt "$KEEP_BACKUPS" ]; then
    for ((i = KEEP_BACKUPS; i < TOTAL_BACKUPS; i++)); do
        OLD_BACKUP="${ALL_BACKUPS[$i]}"
        log "Removing old backup: ${OLD_BACKUP}"
        rm -rf "$OLD_BACKUP"
    done
else
    log "Nothing to rotate (${TOTAL_BACKUPS}/${KEEP_BACKUPS} backups on disk)."
fi

# --- Report current state ----------------------------------------------------
log "Current backups on disk:"
ls -1dt "${BACKUP_ROOT}"/backup_* 2>/dev/null | while read -r b; do
    SIZE=$(du -sh "$b" 2>/dev/null | cut -f1)
    log "  ${b}  (${SIZE})"
done

DISK_FREE=$(df -h "$DATA_MOUNT" | tail -1 | awk '{print $4}')
log "NFS free space remaining: ${DISK_FREE}"

separator
log "Backup run complete."
log ""

exit 0
