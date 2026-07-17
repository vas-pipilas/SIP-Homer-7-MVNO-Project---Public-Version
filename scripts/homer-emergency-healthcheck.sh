#!/bin/bash
# =============================================================================
# homer-emergency-healthcheck.sh
#
# RUN THIS WHEN SOMETHING SEEMS WRONG AND YOU NEED ANSWERS FAST.
#
# Any user can run this -- no sudo required. Scans the whole VM (not just
# Homer-specific things): services, disk, memory, database connectivity,
# ingestion pipeline health, backup status, and logs. For every check that
# finds a problem, it explains in plain language what it likely means and
# what to do about it -- including a clear "contact an admin" escalation
# path for anything that needs elevated access this script itself doesn't
# have.
#
# AI-TOOL-AGNOSTIC BY DESIGN: the output below is meant to be copy-pasted,
# in full, into ANY AI assistant (Claude, ChatGPT, Gemini, whatever you have
# access to) along with a description of what you're experiencing. Every
# check explains itself well enough that an AI with no prior Homer-specific
# context can still help you reason through it.
#
# This script NEVER prompts for a password. Checks needing elevated access
# try a non-interactive sudo call (uses an already-cached sudo session
# only); if that's not available, the check is marked SKIPPED with a note
# on who to contact instead of hanging or failing confusingly.
#
# Not cronjobbed -- run manually, on demand, whenever you need it.
#
# Logs to /var/log/homer/homer-emergency-healthcheck.log (also prints to
# your screen as it runs).
# =============================================================================

LOG_FILE="/var/log/homer/homer-emergency-healthcheck.log"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null && chmod 666 "$LOG_FILE" 2>/dev/null

# --- Colors (only affect terminal display -- every status is also a plain
# text word, so nothing depends on color to be understood) ------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log() { printf '%b\n' "$1" | tee -a "$LOG_FILE"; }

CHECKS_OK=0
CHECKS_WARN=0
CHECKS_CRIT=0
CHECKS_SKIP=0

emit_check() {
    local name="$1" status="$2" detail="$3" guidance="$4" escalate="$5"
    log ""
    log "${CYAN}${BOLD}[CHECK] ${name}${NC}"
    case "$status" in
        OK)
            log "${GREEN}[STATUS] OK${NC}"
            CHECKS_OK=$((CHECKS_OK + 1))
            ;;
        WARN)
            log "${YELLOW}[STATUS] WARN${NC}"
            CHECKS_WARN=$((CHECKS_WARN + 1))
            ;;
        CRIT)
            log "${RED}${BOLD}[STATUS] CRIT${NC}"
            CHECKS_CRIT=$((CHECKS_CRIT + 1))
            ;;
        SKIP)
            log "${MAGENTA}[STATUS] SKIPPED${NC}"
            CHECKS_SKIP=$((CHECKS_SKIP + 1))
            ;;
    esac
    [ -n "$detail" ]    && log "[DETAIL] ${detail}"
    [ -n "$guidance" ]  && log "${BLUE}[GUIDANCE] ${guidance}${NC}"
    [ -n "$escalate" ]  && log "${RED}[ESCALATE] ${escalate}${NC}"
}

ADMIN_CONTACT="the platform admin or the Infrastructure team"

# --- Backup mount point: same shared config as the backup scripts, read-only
# here (never writes if it can't -- this script must work for ANY user,
# including ones without permission to create the config file) -------------
DATA_MOUNT_CONFIG="/etc/homer/data-mount.conf"
DATA_MOUNT_DEFAULT="/data"
[ -f "$DATA_MOUNT_CONFIG" ] && source "$DATA_MOUNT_CONFIG"
if [ -z "$DATA_MOUNT" ]; then
    if [ -t 0 ]; then
        read -r -p "Enter the backup mount point [${DATA_MOUNT_DEFAULT}]: " DATA_MOUNT_INPUT
        DATA_MOUNT="${DATA_MOUNT_INPUT:-$DATA_MOUNT_DEFAULT}"
        echo "DATA_MOUNT=\"${DATA_MOUNT}\"" > "$DATA_MOUNT_CONFIG" 2>/dev/null
        chmod 644 "$DATA_MOUNT_CONFIG" 2>/dev/null
    else
        DATA_MOUNT="$DATA_MOUNT_DEFAULT"
    fi
fi

# --- Non-interactive sudo test: NEVER prompts, only uses an already-cached
# sudo session if one exists. -------------------------------------------------
has_sudo() {
    sudo -n true 2>/dev/null
}

section() {
    log ""
    log "${CYAN}${BOLD}============================================================${NC}"
    log "${CYAN}${BOLD}=== $1 ===${NC}"
    log "${CYAN}${BOLD}============================================================${NC}"
}

log "${CYAN}${BOLD}"
log "============================================================"
log " HOMER EMERGENCY HEALTH CHECK -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
log " Run by: $(whoami)"
log "============================================================"
log "${NC}"
log "If you're stuck after reading this, copy this ENTIRE output and paste"
log "it into any AI assistant along with what you're experiencing -- it has"
log "enough detail embedded to help someone unfamiliar with this platform"
log "reason through it. If any check below says to contact an admin, that"
log "means it needs access this script deliberately doesn't have."

# =============================================================================
section "1. SYSTEM OVERVIEW"
# =============================================================================

UPTIME_OUT=$(uptime)
CPU_CORES=$(nproc 2>/dev/null || echo 1)
LOAD_1MIN=$(echo "$UPTIME_OUT" | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
LOAD_STATUS="OK"
LOAD_GUIDANCE=""
if awk "BEGIN{exit !($LOAD_1MIN > $CPU_CORES * 2)}" 2>/dev/null; then
    LOAD_STATUS="CRIT"
    LOAD_GUIDANCE="1-minute load average (${LOAD_1MIN}) is more than double the CPU core count (${CPU_CORES}). This VM is seriously overloaded right now -- something is consuming far more CPU than normal. Check the next section for which process is responsible before doing anything else."
elif awk "BEGIN{exit !($LOAD_1MIN > $CPU_CORES)}" 2>/dev/null; then
    LOAD_STATUS="WARN"
    LOAD_GUIDANCE="1-minute load average (${LOAD_1MIN}) exceeds the CPU core count (${CPU_CORES}). Worth watching -- check top processes below to see what's driving it."
fi
emit_check "System uptime & load average" "$LOAD_STATUS" "${UPTIME_OUT} | CPU cores: ${CPU_CORES}" "$LOAD_GUIDANCE" ""

TOP5=$(ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | awk '{printf "%s(%s%% cpu) ", $11, $3}')
emit_check "Top 5 processes by CPU" "OK" "$TOP5" "" ""

MEM_LINE=$(free -m | awk '/^Mem:/ {print $2" "$3" "$7}')
MEM_TOTAL=$(echo "$MEM_LINE" | awk '{print $1}')
MEM_USED=$(echo "$MEM_LINE" | awk '{print $2}')
MEM_AVAIL=$(echo "$MEM_LINE" | awk '{print $3}')
MEM_PCT=$(awk "BEGIN{printf \"%.0f\", ($MEM_USED/$MEM_TOTAL)*100}")
MEM_STATUS="OK"
MEM_GUIDANCE=""
if [ "$MEM_PCT" -ge 95 ]; then
    MEM_STATUS="CRIT"
    MEM_GUIDANCE="Memory usage is critically high (${MEM_PCT}%, only ${MEM_AVAIL}MB available). The OS may start killing processes (OOM killer) if this continues. Check top processes above for the likely cause. If nothing obviously wrong stands out, contact an admin before the OOM killer picks for you -- it doesn't always pick the least important process."
elif [ "$MEM_PCT" -ge 85 ]; then
    MEM_STATUS="WARN"
    MEM_GUIDANCE="Memory usage is elevated (${MEM_PCT}%). Worth keeping an eye on, not yet an emergency."
fi
emit_check "Memory usage" "$MEM_STATUS" "${MEM_USED}MB / ${MEM_TOTAL}MB used (${MEM_PCT}%), ${MEM_AVAIL}MB available" "$MEM_GUIDANCE" ""

ROOT_LINE=$(df -h / | tail -1)
ROOT_PCT=$(echo "$ROOT_LINE" | awk '{print $5}' | tr -d '%')
ROOT_AVAIL=$(echo "$ROOT_LINE" | awk '{print $4}')
DISK_STATUS="OK"
DISK_GUIDANCE=""
DISK_ESCALATE=""
if [ "$ROOT_PCT" -ge 85 ]; then
    DISK_STATUS="CRIT"
    DISK_GUIDANCE="Root disk is critically full (${ROOT_PCT}% used, only ${ROOT_AVAIL} free). If this fills completely, PostgreSQL and other services can crash or refuse writes. Check the Database/Storage section below for the likely cause (usually WAL buildup or database growth)."
    DISK_ESCALATE="If you can't identify and free up space quickly, contact ${ADMIN_CONTACT} -- disk expansion requires infrastructure-level access."
elif [ "$ROOT_PCT" -ge 70 ]; then
    DISK_STATUS="WARN"
    DISK_GUIDANCE="Root disk usage is climbing (${ROOT_PCT}% used, ${ROOT_AVAIL} free). Not urgent yet, worth monitoring."
fi
emit_check "Root disk usage" "$DISK_STATUS" "${ROOT_PCT}% used, ${ROOT_AVAIL} free" "$DISK_GUIDANCE" "$DISK_ESCALATE"

# =============================================================================
section "2. CORE SERVICES"
# =============================================================================

for svc in postgresql heplify-server homer-app loki alloy apache2; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$STATE" = "active" ]; then
        emit_check "Service: ${svc}" "OK" "active" "" ""
    elif [ -z "$STATE" ]; then
        emit_check "Service: ${svc}" "SKIP" "could not determine state (unit may not exist under this name, or permission denied)" "If this service should exist on this VM, check the exact unit name with: systemctl list-units --all | grep -i ${svc}" ""
    else
        emit_check "Service: ${svc}" "CRIT" "state: ${STATE}" "This service is not running. If it's postgresql or heplify-server, the entire platform is likely down or not capturing data right now." "Contact ${ADMIN_CONTACT} immediately if this is postgresql, heplify-server, or homer-app -- these are core to the platform."
    fi
done

# =============================================================================
section "3. DATABASE CONNECTIVITY"
# =============================================================================

CRED_FILE="/etc/homer/homer-db-credentials.env"
DB_OK=0
if [ -r "$CRED_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE" 2>/dev/null
    if [ -n "$HOMER_MONITOR_PGPASSWORD" ]; then
        export PGPASSWORD="$HOMER_MONITOR_PGPASSWORD"
        DB_TEST=$(timeout 10 psql -h 127.0.0.1 -p 5432 -U homer_monitor -d homer_data -t -A -c "SELECT 1;" 2>&1)
        if [ "$DB_TEST" = "1" ]; then
            DB_OK=1
            emit_check "PostgreSQL connectivity (homer_data)" "OK" "Connected successfully as homer_monitor" "" ""
        else
            emit_check "PostgreSQL connectivity (homer_data)" "CRIT" "Connection failed: ${DB_TEST}" "The database is unreachable even though the postgresql service may show active above. Could be: PostgreSQL still starting up, connection limit reached, or a config issue." "Contact ${ADMIN_CONTACT} -- this affects the entire platform's ability to capture and query call data."
        fi
        unset PGPASSWORD
    else
        emit_check "PostgreSQL connectivity" "SKIP" "Credentials file exists but is empty or malformed" "" "Contact ${ADMIN_CONTACT} to check /etc/homer/homer-db-credentials.env on the server."
    fi
else
    emit_check "PostgreSQL connectivity" "SKIP" "Cannot read ${CRED_FILE} -- you are likely not a member of the homer-monitor Linux group" "This check needs read access to the shared credentials file. This is normal if you're not yet set up for DB access." "Contact ${ADMIN_CONTACT} to be added to the homer-monitor group if you need this."
fi

if [ "$DB_OK" -eq 1 ]; then
    export PGPASSWORD="$HOMER_MONITOR_PGPASSWORD"
    GAP_CHECK=$(timeout 15 psql -h 127.0.0.1 -p 5432 -U homer_monitor -d homer_data -t -A -F'|' -c "
        SELECT DATE(create_date), MAX(date_trunc('hour', create_date))
        FROM hep_proto_1_call
        WHERE create_date >= NOW() - INTERVAL '2 days'
        GROUP BY DATE(create_date) ORDER BY 1;" 2>/dev/null)
    unset PGPASSWORD
    if [ -z "$GAP_CHECK" ]; then
        emit_check "Recent call-data ingestion (last 2 days)" "WARN" "No rows found for the last 2 days at all" "Either nothing has been captured recently, or the query itself failed silently. Cross-check with the ingestion section below." ""
    else
        LATEST_HOUR=$(echo "$GAP_CHECK" | tail -1 | cut -d'|' -f2)
        emit_check "Recent call-data ingestion (last 2 days)" "OK" "Most recent captured hour: ${LATEST_HOUR}" "" ""
    fi
fi

# =============================================================================
section "4. STORAGE & WAL HEALTH"
# =============================================================================

if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    emit_check "${DATA_MOUNT} NFS backup mount" "OK" "mounted" "" ""
else
    emit_check "${DATA_MOUNT} NFS backup mount" "CRIT" "NOT mounted" "This is the NFS mount used for database backups and WAL archiving. While it's down, PostgreSQL keeps queueing unarchived WAL locally (safe short-term, since Postgres never deletes unarchived WAL) but backups cannot run. This has happened before on this platform due to an unresolved NFS-side issue." "Contact ${ADMIN_CONTACT}. If this has been down for a while, ask about the emergency WAL redirect procedure (homer-wal-emergency-redirect.sh) -- that requires sudo and should be coordinated with an admin, not run solo unless you know exactly what it does."
fi

if has_sudo; then
    WAL_DIR="/var/lib/postgresql/16/main/pg_wal"
    WAL_KB=$(sudo -n du -sk "$WAL_DIR" 2>/dev/null | cut -f1)
    if [ -n "$WAL_KB" ]; then
        WAL_GB=$(awk "BEGIN{printf \"%.2f\", $WAL_KB/1024/1024}")
        WAL_STATUS="OK"
        WAL_GUIDANCE=""
        if awk "BEGIN{exit !($WAL_GB >= 20)}" 2>/dev/null; then
            WAL_STATUS="CRIT"
            WAL_GUIDANCE="PostgreSQL's Write-Ahead Log directory has grown past 20GB. This means WAL archiving has been failing for a while (normally these files get cleared once safely archived to the backup mount). Check the ${DATA_MOUNT} mount status above -- this is almost always caused by that being down."
        elif awk "BEGIN{exit !($WAL_GB >= 15)}" 2>/dev/null; then
            WAL_STATUS="WARN"
            WAL_GUIDANCE="WAL directory is growing (${WAL_GB}GB). Worth checking why archiving might be behind."
        fi
        emit_check "PostgreSQL WAL directory size" "$WAL_STATUS" "${WAL_GB}GB" "$WAL_GUIDANCE" ""
    else
        emit_check "PostgreSQL WAL directory size" "SKIP" "sudo access available but the command still failed" "" "Contact ${ADMIN_CONTACT}."
    fi
else
    emit_check "PostgreSQL WAL directory size" "SKIP" "Requires sudo (this directory is owned by the postgres system user, not readable by regular accounts)" "" "Contact ${ADMIN_CONTACT} if you need this checked and don't have sudo."
fi

for bp in "${DATA_MOUNT}/homer_backup/sip_homer_db_backup" "${DATA_MOUNT}/homer_backup/sip_homer_config_backup"; do
    if [ -d "$bp" ]; then
        emit_check "Backup path exists: ${bp}" "OK" "present" "" ""
    else
        emit_check "Backup path exists: ${bp}" "CRIT" "missing" "This path should always exist if backups are healthy. Could mean ${DATA_MOUNT} is down (see above), or the backup directory structure was disturbed." "Contact ${ADMIN_CONTACT} -- do not attempt to recreate backup directory structure yourself without guidance."
    fi
done

# =============================================================================
section "5. INGESTION PIPELINE HEALTH"
# =============================================================================

WATCHER_LOG="/var/log/homer/homer-pcap-watcher.log"
if [ -f "$WATCHER_LOG" ]; then
    LAST_MOD_EPOCH=$(stat -c %Y "$WATCHER_LOG" 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    AGE_MIN=$(( (NOW_EPOCH - LAST_MOD_EPOCH) / 60 ))
    WATCH_STATUS="OK"
    WATCH_GUIDANCE=""
    if [ "$AGE_MIN" -ge 150 ]; then
        WATCH_STATUS="CRIT"
        WATCH_GUIDANCE="The PCAP import watcher (runs hourly via cron) hasn't written to its log in ${AGE_MIN} minutes -- that's more than 2 missed cycles. Call capture data is likely not being imported into the database right now."
    elif [ "$AGE_MIN" -ge 90 ]; then
        WATCH_STATUS="WARN"
        WATCH_GUIDANCE="The watcher log is ${AGE_MIN} minutes old -- slightly overdue for its hourly run, but only one cycle so far. Could just be timing; worth rechecking in a few minutes."
    fi
    emit_check "PCAP import watcher freshness" "$WATCH_STATUS" "Log last updated ${AGE_MIN} minutes ago" "$WATCH_GUIDANCE" ""
else
    emit_check "PCAP import watcher freshness" "SKIP" "Log file not found at ${WATCHER_LOG}" "" "Contact ${ADMIN_CONTACT} if you expected this to exist."
fi

SANITY_LOG="/var/log/homer/homer-sanity-check.log"
if [ -f "$SANITY_LOG" ]; then
    LAST_MOD_EPOCH=$(stat -c %Y "$SANITY_LOG" 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    AGE_HOURS=$(( (NOW_EPOCH - LAST_MOD_EPOCH) / 3600 ))
    if [ "$AGE_HOURS" -ge 14 ]; then
        emit_check "Sanity check freshness" "WARN" "Last run was ${AGE_HOURS} hours ago" "Sanity check runs twice daily (08:15 and 20:15). Being overdue this long suggests its cron job may not be firing." ""
    else
        emit_check "Sanity check freshness" "OK" "Last run was ${AGE_HOURS} hour(s) ago" "" ""
    fi
else
    emit_check "Sanity check freshness" "SKIP" "Log file not found" "" ""
fi

# =============================================================================
section "6. LOGS & ERRORS"
# =============================================================================

FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null)
if [ -z "$FAILED_UNITS" ]; then
    emit_check "Failed systemd units" "OK" "None" "" ""
else
    emit_check "Failed systemd units" "CRIT" "$FAILED_UNITS" "One or more services have failed and systemd has given up restarting them. Run 'systemctl status <unit>' for details on each." "Contact ${ADMIN_CONTACT} if any of these are core Homer services (postgresql, heplify-server, homer-app, loki, alloy)."
fi

if has_sudo; then
    RECENT_ERRORS=$(sudo -n journalctl -p err -n 20 --no-pager 2>/dev/null)
    if [ -z "$RECENT_ERRORS" ]; then
        emit_check "Recent system journal errors" "OK" "None in recent history" "" ""
    else
        ERR_COUNT=$(echo "$RECENT_ERRORS" | wc -l)
        emit_check "Recent system journal errors" "WARN" "${ERR_COUNT} recent error-level log lines found -- see full log file for details, or run: sudo journalctl -p err -n 50" "Review these for anything matching a service you know is having trouble. Not automatically actionable on its own." ""
    fi
else
    emit_check "Recent system journal errors" "SKIP" "Requires sudo" "" "Contact ${ADMIN_CONTACT} if you need this checked and don't have sudo."
fi

# =============================================================================
section "SUMMARY"
# =============================================================================

log ""
log "$(printf "%-12s %d" "OK:" "$CHECKS_OK")"
log "$(printf "%-12s %d" "WARN:" "$CHECKS_WARN")"
log "$(printf "%-12s %d" "CRIT:" "$CHECKS_CRIT")"
log "$(printf "%-12s %d" "SKIPPED:" "$CHECKS_SKIP")"
log ""

if [ "$CHECKS_CRIT" -gt 0 ]; then
    log "${RED}${BOLD}NEEDS ATTENTION: ${CHECKS_CRIT} critical issue(s) found above.${NC}"
    log "${RED}Review each [CRIT] block's [GUIDANCE] and [ESCALATE] lines. If you're${NC}"
    log "${RED}not confident acting on it yourself, contact ${ADMIN_CONTACT} now.${NC}"
elif [ "$CHECKS_WARN" -gt 0 ]; then
    log "${YELLOW}${BOLD}Some warnings above worth a look, nothing critical right now.${NC}"
else
    log "${GREEN}${BOLD}Everything checked came back healthy.${NC}"
fi

if [ "$CHECKS_SKIP" -gt 0 ]; then
    log ""
    log "${MAGENTA}${CHECKS_SKIP} check(s) were skipped because they need elevated access this${NC}"
    log "${MAGENTA}script doesn't have under your account. See each [SKIP] block above${NC}"
    log "${MAGENTA}for what to do about it.${NC}"
fi

log ""
log "${CYAN}Full log of this run: ${LOG_FILE}${NC}"
log "${CYAN}============================================================${NC}"

exit 0
