#!/usr/bin/env bash
# =============================================================================
# homer-menu.sh — sanitized portfolio edition
# Curated operator console demonstrating consistent UX and risk separation.
# =============================================================================

set -u

BIN_DIR="${HOMER_BIN_DIR:-/usr/local/bin}"
LOG_DIR="${HOMER_LOG_DIR:-/var/log/sip-homer-toolkit}"

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; NC=''
fi

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
|          ~ Production Voice Operations Toolkit ~         |
|                                                          |
============================================================
BANNER
    echo -e "${NC}"
}

pause() { echo; read -r -p "Press Enter to return to the menu..." _; }

run_tool() {
    local tool="$1"; shift
    if [ -x "${BIN_DIR}/${tool}" ]; then
        "${BIN_DIR}/${tool}" "$@"
    else
        echo -e "${YELLOW}[PORTFOLIO NOTE]${NC} ${tool} is not installed at ${BIN_DIR}."
        echo "This public repository is a curated code showcase, not a turnkey production image."
    fi
}

show_file_tail() {
    local file="$1" lines="${2:-40}"
    if [ -r "$file" ]; then tail -n "$lines" "$file"; else echo -e "${YELLOW}[INFO]${NC} No readable log at: $file"; fi
}

vm_menu() {
    while true; do
        header
        echo -e "${MAGENTA}${BOLD} SYSTEM OVERVIEW${NC}"
        echo -e "${CYAN}============================================================${NC}"
        cat <<'EOF'
  1) Uptime and load
  2) Memory usage
  3) Filesystem usage
  4) Failed systemd units
  5) Listening sockets
  6) Top CPU processes
  7) Top memory processes

  0) Back
EOF
        echo -e "${CYAN}============================================================${NC}"
        read -r -p "Enter your choice: " choice
        case "$choice" in
            1) header; uptime; pause ;;
            2) header; free -h; pause ;;
            3) header; df -h; pause ;;
            4) header; systemctl --failed --no-pager; pause ;;
            5) header; ss -tuln; pause ;;
            6) header; ps aux --sort=-%cpu | head -16; pause ;;
            7) header; ps aux --sort=-%mem | head -16; pause ;;
            0) return ;;
            *) echo -e "${YELLOW}[WARN] Invalid choice.${NC}"; sleep 1 ;;
        esac
    done
}

while true; do
    header

    echo -e "${MAGENTA}${BOLD} HEALTH & ANALYTICS${NC}"
    cat <<'EOF'
  1) Emergency health snapshot
  2) Current-hour SIP call statistics
  3) SBC/interconnect route analysis
  4) Historical SBC route summary
EOF

    echo
    echo -e "${MAGENTA}${BOLD} BACKUP OBSERVABILITY${NC}"
    cat <<'EOF'
  5) Daily DB backup status
  6) Show recent backup-status log
EOF

    echo
    echo -e "${MAGENTA}${BOLD} USER LIFECYCLE${NC}"
    cat <<'EOF'
  7) Guided multi-interface user provisioning  [portfolio adapters]
EOF

    echo
    echo -e "${MAGENTA}${BOLD} GIT, DEPLOYMENT & RECOVERY${NC}"
    cat <<'EOF'
  8) Deployment status / source provenance
  9) Curated KNOWN_GOOD restore points
 10) Controlled rollback candidates
EOF

    echo
    echo -e "${MAGENTA}${BOLD} SYSTEM ADMINISTRATION${NC}"
    cat <<'EOF'
 11) VM / Linux system overview  >>
EOF

    echo
    echo -e "${RED}${BOLD} PRIVILEGED WRITE PATHS${NC}"
    cat <<'EOF'
 12) Deploy a Git-backed script       [root + explicit yes]
 13) Promote runtime artifact         [root + explicit yes]
 14) Execute curated rollback         [root + explicit yes]
EOF

    echo
    echo "  0) Exit"
    echo -e "${CYAN}============================================================${NC}"
    read -r -p "Enter your choice: " choice

    case "$choice" in
        1) header; run_tool homer-emergency-healthcheck.sh; pause ;;
        2) header; run_tool homer-callstats.sh; pause ;;
        3) header; run_tool homer-sbc-routes.sh; pause ;;
        4) header; run_tool homer-sbc-routes-summary.sh; pause ;;
        5) header; run_tool homer-db-backup-status.sh; pause ;;
        6) header; show_file_tail "${LOG_DIR}/db-backup.log" 60; pause ;;
        7) header; run_tool homer-user-provision.sh; pause ;;
        8) header; run_tool homer-deploy.sh info; pause ;;
        9) header; run_tool homer-known-good.sh list; pause ;;
        10) header; run_tool homer-rollback.sh list; pause ;;
        11) vm_menu ;;
        12)
            header
            read -r -p "Git-backed script name (e.g. homer-callstats.sh): " file
            run_tool homer-deploy.sh deploy "$file"
            pause
            ;;
        13)
            header
            read -r -p "Runtime script name to curate: " file
            run_tool homer-known-good.sh promote "$file"
            pause
            ;;
        14)
            header
            echo -e "${RED}${BOLD}CONTROLLED ROLLBACK — CURATED KNOWN_GOOD TARGETS ONLY${NC}"
            run_tool homer-rollback.sh list
            echo
            read -r -p "Restore ID: " restore_id
            run_tool homer-rollback.sh rollback "$restore_id"
            pause
            ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}[WARN] Invalid choice.${NC}"; sleep 1 ;;
    esac
done
