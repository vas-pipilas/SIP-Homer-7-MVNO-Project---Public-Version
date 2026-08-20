#!/bin/bash
# =============================================================================
# homer-user-provision.sh — sanitized portfolio edition
#
# Demonstrates the orchestration pattern used when one engineer identity must
# exist across multiple independently-managed interfaces. This public version
# deliberately uses generic child adapters and contains no production account,
# database or pgAdmin details.
#
# Design principles:
#   * collect non-secret identity once;
#   * never collect passwords in the orchestrator;
#   * preflight each account plane before writes;
#   * delegate account creation to guarded child tools;
#   * verify each stage afterward;
#   * make interruption and partial completion explicit;
#   * safely resume by detecting already-completed stages.
# =============================================================================

set -u

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
STATE_DIR="${STATE_DIR:-/var/lib/sip-homer-toolkit}"
LOG_DIR="${LOG_DIR:-/var/log/sip-homer-toolkit}"
AUDIT_LOG="${LOG_DIR}/user-provision.log"

# Fictional adapter names. In a real deployment each adapter owns its own
# password handling, database writes, backups and confirmation semantics.
APP_ADAPTER="${APP_ADAPTER:-${BIN_DIR}/example-app-user-admin.sh}"
ADMIN_ADAPTER="${ADMIN_ADAPTER:-${BIN_DIR}/example-admin-user-admin.sh}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$AUDIT_LOG"
chmod 0640 "$AUDIT_LOG" 2>/dev/null || true

operator() { printf '%s' "${SUDO_USER:-$(id -un)}"; }
sanitize() { printf '%s' "$1" | tr '\n\r|' '___'; }
audit() {
    printf '%s operator=%s action=%s target=%s result=%s detail=%s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%:z')" \
      "$(sanitize "$(operator)")" "$(sanitize "$1")" "$(sanitize "${2:--}")" \
      "$(sanitize "$3")" "$(sanitize "${4:--}")" >> "$AUDIT_LOG"
}

banner() {
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
============================================================
|                                                          |
|                ___  ___ ___ _______  _  _                |
|               / _ \| _ \_ _|_  / _ \| \| |               |
|              | (_) |   /| | / / (_) | .` |               |
|               \___/|_|_\___/___\___/|_|\_|               |
|                                                          |
|            S I P   H O M E R   C O N S O L E             |
|              ~ Guided User Provisioning ~                |
|                                                          |
============================================================
EOF
    echo -e "${NC}"
}

step() {
    echo
    echo -e "${MAGENTA}${BOLD}[ STEP $1 / 2 ]  $2${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

adapter_state() {
    local adapter="$1" email="$2"
    if [ -x "$adapter" ]; then
        "$adapter" exists "$email" >/dev/null 2>&1
    else
        return 2
    fi
}

adapter_verify() {
    local adapter="$1" email="$2"
    [ -x "$adapter" ] && "$adapter" verify "$email" >/dev/null 2>&1
}

run_create() {
    local adapter="$1" email="$2" first="$3" last="$4" department="$5"
    [ -x "$adapter" ] || return 2
    "$adapter" create --email "$email" --first-name "$first" --last-name "$last" --department "$department"
}

abort_handler() {
    echo
    echo -e "${YELLOW}[WARN] Provisioning interrupted.${NC}"
    echo "Partial state may exist. No destructive automatic rollback is attempted."
    echo "Re-run the workflow; preflight will detect verified completed stages."
    audit PROVISION_ABORT "${EMAIL:--}" ABORTED signal_received_rerun_preflight
    exit 130
}
trap abort_handler INT TERM

banner
echo "Identity is collected once. Passwords remain inside each child adapter."
echo "The orchestrator never receives or logs credentials."
echo

while true; do
    read -r -p "Engineer email/login: " EMAIL
    valid_email "$EMAIL" && break
    echo -e "${YELLOW}[WARN] Enter a valid email address.${NC}"
done
read -r -p "First name: " FIRST_NAME
read -r -p "Last name: " LAST_NAME
read -r -p "Department [Engineering]: " DEPARTMENT
DEPARTMENT="${DEPARTMENT:-Engineering}"

audit PROVISION_OPEN "$EMAIL" SUCCESS identity_collected_nonsecret

APP_STATE="CREATE"
ADMIN_STATE="CREATE"
adapter_state "$APP_ADAPTER" "$EMAIL"; rc=$?
[ "$rc" -eq 0 ] && APP_STATE="ALREADY PRESENT / VERIFY"
[ "$rc" -eq 2 ] && APP_STATE="ADAPTER UNAVAILABLE"
adapter_state "$ADMIN_ADAPTER" "$EMAIL"; rc=$?
[ "$rc" -eq 0 ] && ADMIN_STATE="ALREADY PRESENT / VERIFY"
[ "$rc" -eq 2 ] && ADMIN_STATE="ADAPTER UNAVAILABLE"

echo
echo -e "${MAGENTA}${BOLD} PROVISIONING PLAN${NC}"
echo -e "${CYAN}============================================================${NC}"
printf ' %-22s %s\n' "Engineer" "$EMAIL"
printf ' %-22s %s\n' "Application account" "$APP_STATE"
printf ' %-22s %s\n' "Admin-tool account" "$ADMIN_STATE"
echo -e "${CYAN}============================================================${NC}"
read -r -p "Type 'yes' to start/resume this plan: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    audit PROVISION_PLAN "$EMAIL" CANCELLED no_changes_attempted
    exit 0
fi

APP_RESULT="NOT ATTEMPTED"
ADMIN_RESULT="NOT ATTEMPTED"

step 1 "APPLICATION ACCOUNT"
if adapter_verify "$APP_ADAPTER" "$EMAIL"; then
    APP_RESULT="VERIFIED EXISTING"
    echo -e "${GREEN}[OK] Existing account already matches the canonical profile.${NC}"
    audit APP_STAGE "$EMAIL" SKIPPED verified_existing
else
    echo "Delegating creation to the guarded application-account adapter."
    if run_create "$APP_ADAPTER" "$EMAIL" "$FIRST_NAME" "$LAST_NAME" "$DEPARTMENT" && adapter_verify "$APP_ADAPTER" "$EMAIL"; then
        APP_RESULT="VERIFIED CREATED"
        audit APP_STAGE "$EMAIL" SUCCESS created_and_verified
    else
        APP_RESULT="FAILED / NEEDS REVIEW"
        audit APP_STAGE "$EMAIL" FAILED not_verified_after_child_workflow
    fi
fi

step 2 "ADMINISTRATION ACCOUNT"
if adapter_verify "$ADMIN_ADAPTER" "$EMAIL"; then
    ADMIN_RESULT="VERIFIED EXISTING"
    echo -e "${GREEN}[OK] Existing account already matches the canonical profile.${NC}"
    audit ADMIN_STAGE "$EMAIL" SKIPPED verified_existing
else
    echo "Delegating creation to the guarded administration-account adapter."
    if run_create "$ADMIN_ADAPTER" "$EMAIL" "$FIRST_NAME" "$LAST_NAME" "$DEPARTMENT" && adapter_verify "$ADMIN_ADAPTER" "$EMAIL"; then
        ADMIN_RESULT="VERIFIED CREATED"
        audit ADMIN_STAGE "$EMAIL" SUCCESS created_and_verified
    else
        ADMIN_RESULT="FAILED / NEEDS REVIEW"
        audit ADMIN_STAGE "$EMAIL" FAILED not_verified_after_child_workflow
    fi
fi

echo
echo -e "${MAGENTA}${BOLD} FINAL PROVISIONING SUMMARY${NC}"
echo -e "${CYAN}============================================================${NC}"
printf ' %-22s %s\n' "Application" "$APP_RESULT"
printf ' %-22s %s\n' "Administration" "$ADMIN_RESULT"
echo -e "${CYAN}============================================================${NC}"

if [[ "$APP_RESULT" == VERIFIED* ]] && [[ "$ADMIN_RESULT" == VERIFIED* ]]; then
    echo -e "${GREEN}${BOLD}[OK] Provisioning complete across all configured account planes.${NC}"
    audit PROVISION_SUMMARY "$EMAIL" SUCCESS "app=${APP_RESULT};admin=${ADMIN_RESULT}"
else
    echo -e "${YELLOW}[WARN] Provisioning is partial. Re-run safely after reviewing the failed stage.${NC}"
    audit PROVISION_SUMMARY "$EMAIL" PARTIAL "app=${APP_RESULT};admin=${ADMIN_RESULT}"
fi
