#!/bin/bash
# =============================================================================
# homer-menu.sh
# Master interactive console for Homer platform management.
#
# Risk tiers:
#   - Reporting tools            -> run immediately, no confirmation
#   - Backup/prune operations    -> type "yes" to proceed
#   - WAL emergency redirect/restore (mutates live archive_command)
#                                 -> must type the exact word CONFIRM
#
# Privilege handling: any option needing sudo checks first via require_sudo().
#
# Every place that shows a TAILED (truncated) view of a log also prints the
# exact command to view the FULL log file afterward, since all project logs
# are world-readable (chmod 666) — no sudo ever needed just to read one.
#
# IMPORTANT: a few wrapped scripts (daygapcheck, backup-existence-watch,
# wal-watch) aren't yet tracked in this repo — see README for status. Their
# exact log filenames/behavior here are inferred from the project's
# established naming convention.
# =============================================================================

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="/var/log/homer"
BIN_DIR="/usr/local/bin"

# =============================================================================
# HELPERS
# =============================================================================

pause() {
    echo ""
    read -r -p "Press Enter to return to the menu..." _
}

require_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}This action requires sudo privileges.${NC}"
    if sudo -v 2>/dev/null; then
        return 0
    fi
    echo -e "${RED}${BOLD}You don't have sudo access for this action on this system.${NC}"
    echo -e "${YELLOW}Contact your platform admin if you need this capability.${NC}"
    return 1
}

confirm_yes() {
    local prompt="$1"
    echo -e "${YELLOW}${prompt}${NC}"
    read -r -p "Type 'yes' to proceed, anything else to cancel: " ans
    [ "$ans" = "yes" ]
}

confirm_strong() {
    local prompt="$1"
    echo -e "${RED}${BOLD}${prompt}${NC}"
    read -r -p "Type CONFIRM (all caps) to proceed, anything else to cancel: " ans
    [ "$ans" = "CONFIRM" ]
}

show_full_log_hint() {
    local logfile="$1"
    echo ""
    echo -e "${CYAN}Showing a truncated view above. Full log: ${BOLD}cat ${logfile}${NC}"
}

run_and_tail() {
    local cmd="$1" logfile="$2" linesfile="$3"
    eval "$cmd"
    if [ -n "$linesfile" ] && [ -f "$linesfile" ]; then
        tail -n "$(cat "$linesfile" 2>/dev/null || echo 200)" "$logfile"
    else
        tail -n 200 "$logfile"
    fi
    show_full_log_hint "$logfile"
}

prompt_date_args() {
    DATE_ARGS=()
    echo ""
    echo "  1) Today so far (default)"
    echo "  2) A specific date/day"
    echo "  3) A custom start+end range"
    read -r -p "Choose [1]: " mode
    mode="${mode:-1}"
    case "$mode" in
        2)
            read -r -p "Enter a date (any format, e.g. 'yesterday', '2026-07-09', '3 days ago'): " d
            [ -n "$d" ] && DATE_ARGS=("$d")
            ;;
        3)
            read -r -p "Enter START (any format, e.g. '2026-07-07 08:00'): " s
            read -r -p "Enter END   (any format, e.g. '2026-07-07 20:00'): " e
            [ -n "$s" ] && [ -n "$e" ] && DATE_ARGS=("$s" "$e")
            ;;
        *) ;;
    esac
}

header() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'BANNER'
============================================================
|                                                          |
|                ___  ___ ___ _______  _  _                |
|               / _ \| _ \_ _|_  / _ \| \| |               |
|              | (_) |   /| | / / (_) | .` |               |
|               \___/|_|_\___/___\___/|_|\_|               |
|                                                          |
|            S I P   H O M E R   C O N S O L E             |
|             ~ MVNO Voice Network Operations ~            |
|                                                          |
============================================================
BANNER
    echo -e "${NC}"
}

# =============================================================================
# VM / LINUX SYSTEM ADMINISTRATION SUBMENU
# =============================================================================

vm_admin_menu() {
while true; do
header
echo -e "${MAGENTA}${BOLD} VM / LINUX SYSTEM ADMINISTRATION${NC}"
echo -e "${CYAN}============================================================${NC}"
cat <<'EOF'
 SYSTEM OVERVIEW
  1) Uptime & load average
  2) OS / kernel version
  3) Hostname & full system info (uname -a)

 CPU & MEMORY
  4) Live process snapshot (top, one-shot)
  5) Memory usage (free -h)
  6) Top 15 processes by memory

 DISK & STORAGE
  7) Disk usage per filesystem (df -h)
  8) Largest top-level directories (local disk only, skips NFS)
  9) Block devices & mounts

 NETWORK
 10) Network interfaces & IPs
 11) Listening ports              [sudo]
 12) Routing table
 13) Connection summary

 PROCESSES & SERVICES
 14) Top 15 processes by CPU
 15) Failed systemd services
 16) Status of key Homer-stack services
 17) Recent journal errors (last 50)   [sudo]

 USERS & SESSIONS
 18) Who's logged in right now
 19) Last 20 logins

 LOGS
 20) Recent syslog (last 50 lines)
 21) Recent auth log (last 50 lines)   [sudo]
 22) Recent kernel messages (dmesg)    [sudo]

 UPDATES & SECURITY
 23) Available package updates
 24) UFW firewall status               [sudo]

  0) Back to main menu
EOF
echo -e "${CYAN}============================================================${NC}"
read -r -p "Enter your choice: " vchoice

case "$vchoice" in

1)
    header; echo -e "${BLUE}${BOLD}Uptime & load average${NC}\n"
    uptime
    pause
    ;;

2)
    header; echo -e "${BLUE}${BOLD}OS / kernel version${NC}\n"
    cat /etc/os-release
    echo ""
    uname -r
    pause
    ;;

3)
    header; echo -e "${BLUE}${BOLD}Hostname & full system info${NC}\n"
    hostname
    echo ""
    uname -a
    pause
    ;;

4)
    header; echo -e "${BLUE}${BOLD}Live process snapshot${NC}\n"
    top -bn1 | head -20
    pause
    ;;

5)
    header; echo -e "${BLUE}${BOLD}Memory usage${NC}\n"
    free -h
    pause
    ;;

6)
    header; echo -e "${BLUE}${BOLD}Top 15 processes by memory${NC}\n"
    ps aux --sort=-%mem | head -16
    pause
    ;;

7)
    header; echo -e "${BLUE}${BOLD}Disk usage per filesystem${NC}\n"
    df -h
    pause
    ;;

8)
    header; echo -e "${BLUE}${BOLD}Largest top-level directories (local disk only)${NC}\n"
    echo "(Scanning / with -x, so NFS mounts like /data are skipped — may take a few seconds)"
    echo ""
    du -shx /* 2>/dev/null | sort -rh | head -15
    pause
    ;;

9)
    header; echo -e "${BLUE}${BOLD}Block devices & mounts${NC}\n"
    lsblk
    echo ""
    echo "--- Mounts ---"
    mount | grep -E "^/dev|nfs"
    pause
    ;;

10)
    header; echo -e "${BLUE}${BOLD}Network interfaces & IPs${NC}\n"
    ip -brief addr show
    pause
    ;;

11)
    header; echo -e "${BLUE}${BOLD}Listening ports${NC}\n"
    if require_sudo; then
        sudo ss -tulnp
    fi
    pause
    ;;

12)
    header; echo -e "${BLUE}${BOLD}Routing table${NC}\n"
    ip route
    pause
    ;;

13)
    header; echo -e "${BLUE}${BOLD}Connection summary${NC}\n"
    ss -s
    pause
    ;;

14)
    header; echo -e "${BLUE}${BOLD}Top 15 processes by CPU${NC}\n"
    ps aux --sort=-%cpu | head -16
    pause
    ;;

15)
    header; echo -e "${BLUE}${BOLD}Failed systemd services${NC}\n"
    systemctl --failed --no-pager
    pause
    ;;

16)
    header; echo -e "${BLUE}${BOLD}Status of key Homer-stack services${NC}\n"
    for svc in postgresql heplify-server loki alloy; do
        state=$(systemctl is-active "${svc}" 2>/dev/null)
        printf "%-20s %s\n" "$svc" "$state"
    done
    pause
    ;;

17)
    header; echo -e "${BLUE}${BOLD}Recent journal errors (last 50)${NC}\n"
    if require_sudo; then
        sudo journalctl -p err -n 50 --no-pager
    fi
    pause
    ;;

18)
    header; echo -e "${BLUE}${BOLD}Who's logged in right now${NC}\n"
    who
    echo ""
    w
    pause
    ;;

19)
    header; echo -e "${BLUE}${BOLD}Last 20 logins${NC}\n"
    last -n 20
    pause
    ;;

20)
    header; echo -e "${BLUE}${BOLD}Recent syslog (last 50 lines)${NC}\n"
    tail -50 /var/log/syslog
    pause
    ;;

21)
    header; echo -e "${BLUE}${BOLD}Recent auth log (last 50 lines)${NC}\n"
    if require_sudo; then
        sudo tail -50 /var/log/auth.log
    fi
    pause
    ;;

22)
    header; echo -e "${BLUE}${BOLD}Recent kernel messages${NC}\n"
    if require_sudo; then
        sudo dmesg | tail -50
    fi
    pause
    ;;

23)
    header; echo -e "${BLUE}${BOLD}Available package updates${NC}\n"
    apt list --upgradable 2>/dev/null
    pause
    ;;

24)
    header; echo -e "${BLUE}${BOLD}UFW firewall status${NC}\n"
    if require_sudo; then
        if command -v ufw &>/dev/null; then
            sudo ufw status verbose
        else
            echo "ufw is not installed on this system."
        fi
    fi
    pause
    ;;

0)
    return
    ;;

*)
    echo -e "${RED}Invalid choice.${NC}"
    sleep 1
    ;;
esac
done
}

# =============================================================================
# MAIN MENU LOOP
# =============================================================================

while true; do
header
cat <<'EOF'
 HEALTH & MONITORING
  1) Live monitor snapshot
  2) Full health / sanity check                 [sudo]
  3) Health check history (last 60 lines)
  4) Watcher timeline (import history)
  5) Day gap check
  6) WAL health check (pg_wal size/disk usage)  [sudo]
  7) Backup existence check (4 critical paths)  [sudo]
 21) Full emergency health check (any user, no sudo needed)
 22) DB deep health check (locks, bloat, slow queries, etc.)

 CALL STATISTICS
  8) Current hour call stats
  9) Historical call stats graph (pick a date/range)

 SBC ROUTE ANALYSIS
 10) Current hour SBC route report
 11) Historical SBC route summary (pick a date/range)

 SYSTEM ADMINISTRATION
 20) VM / Linux System Administration  >>

 USER MANAGEMENT
 12) Change my Homer GUI password
 13) User management (add/list/remove users)   [sudo]

 BACKUP & RECOVERY
 14) Manual full DB base backup            [sudo] [confirm]
 15) Manual config backup                  [sudo]
 16) Config restore (browse + decrypt for review) [sudo]
 17) Manual WAL prune                      [sudo] [confirm]

 EMERGENCY — NFS/WAL OUTAGE TOOLS          [high risk]
 18) WAL emergency redirect (start)        [sudo] [CONFIRM]
 19) WAL emergency restore (revert)        [sudo] [CONFIRM]

  0) Exit
EOF
echo -e "${CYAN}============================================================${NC}"
read -r -p "Enter your choice: " choice

case "$choice" in

1)
    header; echo -e "${BLUE}${BOLD}Live monitor snapshot${NC}\n"
    "${BIN_DIR}/homer-monitor.sh"
    pause
    ;;

2)
    header; echo -e "${BLUE}${BOLD}Full health / sanity check${NC}\n"
    if require_sudo; then
        sudo "${BIN_DIR}/homer-sanity-check.sh" && sudo cat "${LOG_DIR}/homer-sanity-check.log"
    fi
    pause
    ;;

3)
    header; echo -e "${BLUE}${BOLD}Health check history (last 60 lines)${NC}\n"
    tail -60 "${LOG_DIR}/homer-sanity-check.log"
    show_full_log_hint "${LOG_DIR}/homer-sanity-check.log"
    pause
    ;;

4)
    header; echo -e "${BLUE}${BOLD}Watcher timeline${NC}\n"
    "${BIN_DIR}/homer-watcher-timeline.sh"
    pause
    ;;

5)
    header; echo -e "${BLUE}${BOLD}Day gap check${NC}\n"
    "${BIN_DIR}/homer-day-gap-check.sh"
    pause
    ;;

6)
    header; echo -e "${BLUE}${BOLD}WAL health check${NC}\n"
    if require_sudo; then
        sudo "${BIN_DIR}/homer-wal-watch.sh"
    fi
    pause
    ;;

7)
    header; echo -e "${BLUE}${BOLD}Backup existence check${NC}\n"
    if require_sudo; then
        sudo "${BIN_DIR}/homer-backup-existence-watch.sh"
        if [ -f "${LOG_DIR}/homer-backup-existence-watch.log" ]; then
            echo ""
            echo "--- Last 10 log lines ---"
            tail -10 "${LOG_DIR}/homer-backup-existence-watch.log"
            show_full_log_hint "${LOG_DIR}/homer-backup-existence-watch.log"
        fi
    fi
    pause
    ;;

8)
    header; echo -e "${BLUE}${BOLD}Current hour call stats${NC}\n"
    run_and_tail "${BIN_DIR}/homer-callstats.sh" \
        "${LOG_DIR}/homer-callstats.log" \
        "${LOG_DIR}/homer-callstats.log.lines"
    pause
    ;;

9)
    header; echo -e "${BLUE}${BOLD}Historical call stats graph${NC}"
    prompt_date_args
    header; echo -e "${BLUE}${BOLD}Historical call stats graph${NC}\n"
    run_and_tail "${BIN_DIR}/homer-callstats-daily-graph.sh ${DATE_ARGS[*]@Q}" \
        "${LOG_DIR}/homer-callstats-daily-graph.log" \
        "${LOG_DIR}/homer-callstats-daily-graph.log.lines"
    pause
    ;;

10)
    header; echo -e "${BLUE}${BOLD}Current hour SBC route report${NC}\n"
    run_and_tail "${BIN_DIR}/homer-sbc-routes.sh" \
        "${LOG_DIR}/homer-sbc-routes.log" \
        "${LOG_DIR}/homer-sbc-routes.log.lines"
    pause
    ;;

11)
    header; echo -e "${BLUE}${BOLD}Historical SBC route summary${NC}"
    prompt_date_args
    header; echo -e "${BLUE}${BOLD}Historical SBC route summary${NC}\n"
    run_and_tail "${BIN_DIR}/homer-sbc-routes-summary.sh ${DATE_ARGS[*]@Q}" \
        "${LOG_DIR}/homer-sbc-routes-summary.log" \
        "${LOG_DIR}/homer-sbc-routes-summary.log.lines"
    pause
    ;;

12)
    header; echo -e "${BLUE}${BOLD}Change my Homer GUI password${NC}\n"
    "${BIN_DIR}/homer-change-password.sh"
    pause
    ;;

13)
    header; echo -e "${BLUE}${BOLD}User management${NC}\n"
    if require_sudo; then
        sudo "${BIN_DIR}/homer-add-user.sh"
    fi
    pause
    ;;

14)
    header
    if require_sudo && confirm_yes "This runs a full pg_basebackup — resource-intensive, prefer off-peak hours. Continue?"; then
        header; echo -e "${BLUE}${BOLD}Manual full DB base backup${NC}\n"
        sudo "${BIN_DIR}/homer-db-backup.sh"
        echo ""
        tail -40 "${LOG_DIR}/homer-db-backup.log"
        show_full_log_hint "${LOG_DIR}/homer-db-backup.log"
    else
        echo "Cancelled."
    fi
    pause
    ;;

15)
    header
    if require_sudo && confirm_yes "Run a manual encrypted config backup now?"; then
        header; echo -e "${BLUE}${BOLD}Manual config backup${NC}\n"
        sudo "${BIN_DIR}/homer-config-backup.sh"
        echo ""
        tail -40 "${LOG_DIR}/homer-config-backup.log"
        show_full_log_hint "${LOG_DIR}/homer-config-backup.log"
    else
        echo "Cancelled."
    fi
    pause
    ;;

16)
    header; echo -e "${BLUE}${BOLD}Config restore — available backups${NC}\n"
    if require_sudo; then
        sudo "${BIN_DIR}/homer-config-restore.sh"
        echo ""
        read -r -p "Paste the full path of the backup to restore (or press Enter to cancel): " backup_path
        if [ -n "$backup_path" ]; then
            sudo "${BIN_DIR}/homer-config-restore.sh" "$backup_path"
        else
            echo "Cancelled."
        fi
    fi
    pause
    ;;

17)
    header
    if require_sudo && confirm_yes "This deletes archived WAL segments older than the retention cutoff (internally safety-checked against your oldest backup). Continue?"; then
        header; echo -e "${BLUE}${BOLD}Manual WAL prune${NC}\n"
        sudo "${BIN_DIR}/homer-wal-prune.sh"
        echo ""
        tail -40 "${LOG_DIR}/homer-wal-prune.log"
        show_full_log_hint "${LOG_DIR}/homer-wal-prune.log"
    else
        echo "Cancelled."
    fi
    pause
    ;;

18)
    header
    if require_sudo && confirm_strong "This switches archive_command to redirect WAL to the emergency holding directory — a LIVE Postgres config change. Only use this during a confirmed /data outage."; then
        header; echo -e "${BLUE}${BOLD}WAL emergency redirect${NC}\n"
        sudo "${BIN_DIR}/homer-wal-emergency-redirect.sh"
        echo ""
        tail -20 "${LOG_DIR}/homer-wal-emergency.log"
        show_full_log_hint "${LOG_DIR}/homer-wal-emergency.log"
    else
        echo "Cancelled."
    fi
    pause
    ;;

19)
    header
    if require_sudo && confirm_strong "This reverts archive_command back to its saved value — only do this once the real NFS backup mount is confirmed back AND a fresh base backup has been taken."; then
        header; echo -e "${BLUE}${BOLD}WAL emergency restore${NC}\n"
        sudo "${BIN_DIR}/homer-wal-emergency-restore.sh"
        echo ""
        tail -20 "${LOG_DIR}/homer-wal-emergency.log"
        show_full_log_hint "${LOG_DIR}/homer-wal-emergency.log"
    else
        echo "Cancelled."
    fi
    pause
    ;;

20)
    vm_admin_menu
    ;;

21)
    header; echo -e "${BLUE}${BOLD}Full emergency health check${NC}\n"
    "${BIN_DIR}/homer-emergency-healthcheck.sh"
    show_full_log_hint "${LOG_DIR}/homer-emergency-healthcheck.log"
    pause
    ;;

22)
    header; echo -e "${BLUE}${BOLD}DB deep health check${NC}\n"
    "${BIN_DIR}/homer-db-deep-health.sh"
    show_full_log_hint "${LOG_DIR}/homer-db-deep-health.log"
    pause
    ;;

0)
    echo "Goodbye."
    exit 0
    ;;

*)
    echo -e "${RED}Invalid choice.${NC}"
    sleep 1
    ;;
esac
done
