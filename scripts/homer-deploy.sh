#!/usr/bin/env bash
# =============================================================================
# homer-deploy.sh — sanitized portfolio edition
# Guarded Git -> runtime deployment with diff, validation, backup and provenance.
#
# This public version uses generic configurable paths. It demonstrates the
# safety model without exposing production repository names or infrastructure.
# =============================================================================

set -u

REPO_DIR="${HOMER_REPO_DIR:-/opt/sip-homer-toolkit}"
SOURCE_DIR="${REPO_DIR}/scripts"
LIVE_DIR="${HOMER_LIVE_DIR:-/usr/local/bin}"
LOG_DIR="${HOMER_LOG_DIR:-/var/log/sip-homer-toolkit}"
LEDGER="${LOG_DIR}/deployment-ledger.tsv"
BACKUP_DIR="${HOMER_DEPLOY_BACKUP_DIR:-/var/backups/sip-homer-toolkit/deployments}"
BRANCH="${HOMER_DEPLOY_BRANCH:-main}"

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
    [ "$EUID" -eq 0 ] || { error "Deployment writes require root/authorized administration."; exit 1; }
}

require_repo() {
    [ -d "${REPO_DIR}/.git" ] || { error "Git repository not found: ${REPO_DIR}"; exit 1; }
    [ -d "$SOURCE_DIR" ] || { error "Source directory not found: ${SOURCE_DIR}"; exit 1; }
}

repo_branch() { git -C "$REPO_DIR" branch --show-current; }
repo_sha()    { git -C "$REPO_DIR" rev-parse HEAD; }
repo_short()  { git -C "$REPO_DIR" rev-parse --short HEAD; }
repo_clean()  { [ -z "$(git -C "$REPO_DIR" status --porcelain)" ]; }

validate_repo_state() {
    local current
    current="$(repo_branch)"
    [ "$current" = "$BRANCH" ] || {
        error "Repository is on '${current}', expected '${BRANCH}'."
        return 1
    }
    repo_clean || {
        error "Working tree is dirty. Commit/review changes before deployment."
        git -C "$REPO_DIR" status --short
        return 1
    }
}

safe_name() {
    [[ "$1" =~ ^homer-[A-Za-z0-9._-]+\.(sh|py)$ ]]
}

source_path() { printf '%s/%s' "$SOURCE_DIR" "$1"; }
live_path()   { printf '%s/%s' "$LIVE_DIR" "$1"; }

validate_source() {
    local file="$1"
    case "$file" in
        *.sh) bash -n "$file" ;;
        *.py) python3 -m py_compile "$file" ;;
        *) return 1 ;;
    esac
}

show_info() {
    require_repo
    printf '%s\n' "GUARDED DEPLOYMENT STATUS"
    printf '%s\n' "------------------------------------------------------------"
    printf '%-14s %s\n' "Repository" "$REPO_DIR"
    printf '%-14s %s\n' "Branch" "$(repo_branch)"
    printf '%-14s %s\n' "Commit" "$(repo_short)"
    printf '%-14s %s\n' "Runtime" "$LIVE_DIR"
    printf '%-14s %s\n' "Ledger" "$LEDGER"
}

show_diff() {
    local name="$1" src live
    safe_name "$name" || { error "Unsupported file name: $name"; return 2; }
    src="$(source_path "$name")"; live="$(live_path "$name")"
    [ -f "$src" ] || { error "Git source does not exist: $src"; return 1; }

    if [ ! -e "$live" ]; then
        diff -u --label /dev/null --label "GIT:${name}" /dev/null "$src" || true
    elif cmp -s "$src" "$live"; then
        ok "$name is byte-identical to runtime."
    else
        diff -u --label "LIVE:${name}" --label "GIT:${name}" "$live" "$src" || true
    fi
}

append_ledger() {
    local name="$1" previous="$2" old_sha="$3" new_sha="$4" backup="$5"
    mkdir -p "$LOG_DIR" || return 1
    touch "$LEDGER" || return 1
    printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tSUCCESS\n' \
        "$(date --iso-8601=seconds)" "$(repo_sha)" "$name" "$previous" \
        "$old_sha" "$new_sha" "$backup" "$(id -un)" >> "$LEDGER"
}

deploy_one() {
    local name="$1" src live old_sha="NONE" new_sha backup="NONE" previous="NEW"

    require_root
    require_repo
    validate_repo_state || exit 1
    safe_name "$name" || { error "Unsupported deployable name: $name"; exit 2; }

    src="$(source_path "$name")"; live="$(live_path "$name")"
    [ -f "$src" ] || { error "Source not found: $src"; exit 1; }

    info "Validating Git source before touching runtime..."
    validate_source "$src" || { error "Source validation failed."; exit 1; }

    echo
    show_diff "$name"
    echo

    if [ -e "$live" ] && cmp -s "$src" "$live"; then
        ok "No deployment required."
        exit 0
    fi

    read -r -p "Type 'yes' to deploy ${name}: " confirm
    [ "$confirm" = "yes" ] || { info "Deployment cancelled."; exit 0; }

    mkdir -p "$LIVE_DIR" "$BACKUP_DIR" "$LOG_DIR" || { error "Unable to prepare runtime directories."; exit 1; }

    if [ -e "$live" ]; then
        previous="EXISTING"
        old_sha="$(sha256sum "$live" | awk '{print $1}')"
        backup="${BACKUP_DIR}/${name}.$(date '+%Y%m%d_%H%M%S').bak"
        cp -a -- "$live" "$backup" || { error "Runtime backup failed; deployment stopped."; exit 1; }
        ok "Previous runtime artifact backed up: $backup"
    fi

    install -m 0755 -- "$src" "$live" || { error "Installation failed."; exit 1; }
    validate_source "$live" || { error "Installed artifact failed validation."; exit 1; }

    new_sha="$(sha256sum "$live" | awk '{print $1}')"
    [ "$new_sha" = "$(sha256sum "$src" | awk '{print $1}')" ] || {
        error "Post-install checksum mismatch."
        exit 1
    }

    append_ledger "$name" "$previous" "$old_sha" "$new_sha" "$backup" || {
        error "Deployment succeeded but provenance ledger write failed. Review immediately."
        exit 1
    }

    ok "Deployed ${name} from Git commit $(repo_short)."
    ok "SHA256: $new_sha"
}

show_history() {
    [ -f "$LEDGER" ] || { info "No deployment ledger exists yet."; return 0; }
    tail -n "${1:-20}" "$LEDGER"
}

usage() {
    cat <<EOF
Usage:
  $0 info
  $0 diff <homer-script.sh|py>
  $0 deploy <homer-script.sh|py>
  $0 history [lines]

Public portfolio defaults:
  repo    : $REPO_DIR
  runtime : $LIVE_DIR

Override paths with HOMER_REPO_DIR, HOMER_LIVE_DIR, HOMER_LOG_DIR and
HOMER_DEPLOY_BACKUP_DIR when testing in a lab.
EOF
}

case "${1:-}" in
    info)    show_info ;;
    diff)    [ "$#" -eq 2 ] || { usage; exit 2; }; require_repo; show_diff "$2" ;;
    deploy)  [ "$#" -eq 2 ] || { usage; exit 2; }; deploy_one "$2" ;;
    history) show_history "${2:-20}" ;;
    *)       usage; exit 2 ;;
esac
