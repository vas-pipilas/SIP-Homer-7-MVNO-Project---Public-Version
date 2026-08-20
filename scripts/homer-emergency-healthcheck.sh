#!/bin/bash
# =============================================================================
# homer-emergency-healthcheck.sh — sanitized portfolio edition
#
# Read-mostly, operator-facing triage for a SIP monitoring VM. The output is
# intentionally explanatory: each failed check includes likely meaning and a
# safe escalation path. The script never prompts for sudo credentials.
#
# All database names, paths and identities are fictionalized.
# =============================================================================

set -u

LOG_DIR="/var/log/sip-homer-toolkit"
LOG_FILE="${LOG_DIR}/emergency-healthcheck.log"
CRED_FILE="/etc/sip-homer-toolkit/db.env"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/example/backups/postgres/base}"
STATE_FILE="${STATE_FILE:-/var/lib/sip-homer-toolkit/backup-verify.state}"
DB_NAME="sip_capture"
DB_USER="sip_monitor"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

OK_COUNT=0; WARN_COUNT=0; CRIT_COUNT=0; SKIP_COUNT=0
log() { printf '%b\n' "$1" | tee -a "$LOG_FILE"; }
section() { log ""; log "${CYAN}${BOLD}============================================================${NC}"; log "${CYAN}${BOLD}$1${NC}"; log "${CYAN}${BOLD}============================================================${NC}"; }

emit() {
    local name="$1" status="$2" detail="$3" guidance="${4:-}"
    log ""
    log "${CYAN}${BOLD}[CHECK] ${name}${NC}"
    case "$status" in
        OK)   log "${GREEN}[STATUS] OK${NC}"; OK_COUNT=$((OK_COUNT+1)) ;;
        WARN) log "${YELLOW}[STATUS] WARN${NC}"; WARN_COUNT=$((WARN_COUNT+1)) ;;
        CRIT) log "${RED}${BOLD}[STATUS] CRIT${NC}"; CRIT_COUNT=$((CRIT_COUNT+1)) ;;
        *)    log "${MAGENTA}[STATUS] SKIPPED${NC}"; SKIP_COUNT=$((SKIP_COUNT+1)) ;;
    esac
    [ -n "$detail" ] && log "[DETAIL] ${detail}"
    [ -n "$guidance" ] && log "[GUIDANCE] ${guidance}"
}

has_cached_sudo() { sudo -n true >/dev/null 2>&1; }

log "${CYAN}${BOLD}============================================================${NC}"
log " SIP HOMER EMERGENCY HEALTH CHECK — $(date '+%Y-%m-%d %H:%M:%S %Z')"
log " Operator: $(id -un)"
log "${CYAN}${BOLD}============================================================${NC}"
log "This check does not mutate the SIP platform. Privileged checks use only an already-cached sudo session and are skipped otherwise."

section "1. HOST HEALTH"

LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
CPU=$(nproc 2>/dev/null || echo 1)
if awk "BEGIN{exit !($LOAD > $CPU*2)}"; then
    emit "CPU load" CRIT "1-minute load=${LOAD}, cores=${CPU}" "Identify top CPU consumers before restarting services."
elif awk "BEGIN{exit !($LOAD > $CPU)}"; then
    emit "CPU load" WARN "1-minute load=${LOAD}, cores=${CPU}" "Watch for sustained pressure and correlate with processes."
else
    emit "CPU load" OK "1-minute load=${LOAD}, cores=${CPU}"
fi

MEM_PCT=$(free | awk '/^Mem:/ {printf "%.0f",100*$3/$2}')
MEM_AVAIL=$(free -h | awk '/^Mem:/ {print $7}')
if [ "${MEM_PCT:-0}" -ge 95 ]; then
    emit "Memory" CRIT "${MEM_PCT}% used, ${MEM_AVAIL} available" "Risk of OOM kills; identify memory-heavy processes."
elif [ "${MEM_PCT:-0}" -ge 85 ]; then
    emit "Memory" WARN "${MEM_PCT}% used, ${MEM_AVAIL} available"
else
    emit "Memory" OK "${MEM_PCT}% used, ${MEM_AVAIL} available"
fi

ROOT_PCT=$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')
ROOT_FREE=$(df -hP / | awk 'NR==2{print $4}')
if [ "${ROOT_PCT:-0}" -ge 90 ]; then
    emit "Root filesystem" CRIT "${ROOT_PCT}% used, ${ROOT_FREE} free" "A full filesystem can stop PostgreSQL writes and logging."
elif [ "${ROOT_PCT:-0}" -ge 80 ]; then
    emit "Root filesystem" WARN "${ROOT_PCT}% used, ${ROOT_FREE} free"
else
    emit "Root filesystem" OK "${ROOT_PCT}% used, ${ROOT_FREE} free"
fi

section "2. CORE SERVICES"
for svc in postgresql heplify-server homer-app; do
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    case "$state" in
        active) emit "Service ${svc}" OK active ;;
        inactive|failed) emit "Service ${svc}" CRIT "state=${state}" "Core SIP visibility may be degraded; inspect the service journal before restart." ;;
        *) emit "Service ${svc}" SKIP "state unavailable or unit name differs in this example environment" ;;
    esac
done

section "3. DATABASE & INGESTION"
DB_OK=0
if [ -r "$CRED_FILE" ]; then
    # Expected variable: SIP_MONITOR_PGPASSWORD
    # shellcheck disable=SC1090
    source "$CRED_FILE"
    if [ -n "${SIP_MONITOR_PGPASSWORD:-}" ]; then
        export PGPASSWORD="$SIP_MONITOR_PGPASSWORD"
        result=$(timeout 10 psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1;' 2>&1 || true)
        if [ "$result" = "1" ]; then
            DB_OK=1
            emit "PostgreSQL connectivity" OK "Connected using restricted monitoring role."
        else
            emit "PostgreSQL connectivity" CRIT "Connection test failed." "Check PostgreSQL state, connection limits and local authentication configuration."
        fi
    else
        emit "PostgreSQL connectivity" SKIP "Credential environment file is readable but expected variable is absent."
    fi
else
    emit "PostgreSQL connectivity" SKIP "Restricted monitoring credential file is not readable by this user."
fi

if [ "$DB_OK" -eq 1 ]; then
    latest=$(timeout 15 psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT MAX(create_date) FROM hep_proto_1_call;" 2>/dev/null || true)
    if [ -n "$latest" ]; then
        emit "Latest captured SIP record" OK "$latest"
    else
        emit "Latest captured SIP record" WARN "No timestamp returned." "Correlate with watcher/import logs and HEP receiver health."
    fi
    unset PGPASSWORD
fi

section "4. BACKUP OBSERVABILITY"
LATEST=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'backup_*' -printf '%T@|%f\n' 2>/dev/null | sort -nr | head -1)
if [ -z "$LATEST" ]; then
    emit "Retained base backup" CRIT "No backup directory found under the generalized backup root." "Confirm storage availability and the scheduled backup job."
else
    epoch=${LATEST%%|*}; name=${LATEST#*|}; age=$(( ( $(date +%s) - ${epoch%.*} ) / 86400 ))
    if [ "$age" -le 7 ]; then
        emit "Retained base backup" OK "${name}, age=${age} day(s)"
    elif [ "$age" -le 10 ]; then
        emit "Retained base backup" WARN "${name}, age=${age} day(s)" "Weekly backup appears overdue."
    else
        emit "Retained base backup" CRIT "${name}, age=${age} day(s)" "Backup is stale; investigate scheduler/storage before trusting recoverability."
    fi
fi

if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    case "${STATUS:-UNKNOWN}" in
        PASS) emit "Deep restore verification" OK "backup=${BACKUP_ID:-unknown}, checked=${LAST_CHECKED:-unknown}" ;;
        FAIL) emit "Deep restore verification" CRIT "backup=${BACKUP_ID:-unknown}, checked=${LAST_CHECKED:-unknown}" "The latest deep restore test failed; do not treat backup existence as recoverability." ;;
        *) emit "Deep restore verification" WARN "status=${STATUS:-UNKNOWN}" "Verification may still be pending or the verifier may not be running." ;;
    esac
else
    emit "Deep restore verification" WARN "No state file available." "Confirm the scheduled deep-restore verifier is configured."
fi

section "5. PRIVILEGED OPTIONAL CHECKS"
if has_cached_sudo; then
    WAL_DIR=$(sudo -n -u postgres psql -tAc 'SHOW data_directory;' 2>/dev/null)/pg_wal
    if [ -d "$WAL_DIR" ]; then
        size=$(sudo -n du -sh "$WAL_DIR" 2>/dev/null | awk '{print $1}')
        emit "PostgreSQL WAL directory" OK "size=${size:-unknown}" "Trend this value; unexpected sustained growth can indicate archive failure."
    else
        emit "PostgreSQL WAL directory" SKIP "Could not resolve pg_wal path."
    fi
else
    emit "PostgreSQL WAL directory" SKIP "No cached sudo authorization; script will not prompt."
fi

section "SUMMARY"
log "OK=${OK_COUNT} WARN=${WARN_COUNT} CRIT=${CRIT_COUNT} SKIPPED=${SKIP_COUNT}"
if [ "$CRIT_COUNT" -gt 0 ]; then
    log "${RED}${BOLD}Overall: CRITICAL findings require investigation.${NC}"
elif [ "$WARN_COUNT" -gt 0 ]; then
    log "${YELLOW}Overall: platform reachable, but warnings require review.${NC}"
else
    log "${GREEN}${BOLD}Overall: no critical findings in the checks that could run.${NC}"
fi
log "This public implementation is intentionally generalized; adapt unit names, paths and thresholds to the target environment."
