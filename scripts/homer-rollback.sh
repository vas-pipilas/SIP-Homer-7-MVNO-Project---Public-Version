#!/usr/bin/env bash
# =============================================================================
# homer-rollback.sh — sanitized portfolio edition
# Restores only curated KNOWN_GOOD artifacts, with preview, checksum validation,
# live backup and provenance logging.
# =============================================================================

set -u

LIVE_DIR="${HOMER_LIVE_DIR:-/usr/local/bin}"
STATE_DIR="${HOMER_RECOVERY_STATE_DIR:-/var/lib/sip-homer-toolkit/known-good}"
INDEX="${STATE_DIR}/index.tsv"
BACKUP_DIR="${HOMER_ROLLBACK_BACKUP_DIR:-/var/backups/sip-homer-toolkit/rollbacks}"
LOG_DIR="${HOMER_LOG_DIR:-/var/log/sip-homer-toolkit}"
LEDGER="${LOG_DIR}/deployment-ledger.tsv"

require_root() {
    [ "$EUID" -eq 0 ] || { echo "[ERROR] Rollback requires root/authorized administration." >&2; exit 1; }
}

metadata_value() {
    local file="$1" key="$2"
    awk -F '=' -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

resolve_point() {
    local id="$1" meta
    meta="${STATE_DIR}/${id}/metadata.env"
    [ -r "$meta" ] || { echo "[ERROR] Restore metadata not found: $id" >&2; return 1; }

    RESTORE_ID="$(metadata_value "$meta" RESTORE_ID)"
    FILE="$(metadata_value "$meta" FILE)"
    SOURCE_REF="$(metadata_value "$meta" SOURCE_REF)"
    EXPECTED_SHA="$(metadata_value "$meta" SHA256)"
    STATE="$(metadata_value "$meta" STATE)"
    ARTIFACT="${STATE_DIR}/${id}/${FILE}"
    LIVE="${LIVE_DIR}/${FILE}"

    [ "$RESTORE_ID" = "$id" ] || { echo "[ERROR] Metadata ID mismatch." >&2; return 1; }
    [ "$STATE" = "KNOWN_GOOD" ] || { echo "[ERROR] Restore point is not eligible: state=$STATE" >&2; return 1; }
    [ -f "$ARTIFACT" ] || { echo "[ERROR] Curated artifact missing." >&2; return 1; }
    [ "$(sha256sum "$ARTIFACT" | awk '{print $1}')" = "$EXPECTED_SHA" ] || {
        echo "[ERROR] Curated artifact checksum mismatch." >&2
        return 1
    }
}

list_points() {
    [ -f "$INDEX" ] || { echo "No curated restore points yet."; return 0; }
    awk -F '\t' '$6=="KNOWN_GOOD" {printf "%-28s %-32s %-14s %s\n",$1,$2,$3,$4}' "$INDEX"
}

preview() {
    local id="$1" live_sha="MISSING"
    resolve_point "$id" || return 1

    [ -f "$LIVE" ] && live_sha="$(sha256sum "$LIVE" | awk '{print $1}')"

    echo "CONTROLLED ROLLBACK PREVIEW"
    echo "------------------------------------------------------------"
    printf '%-16s %s\n' "Restore ID" "$RESTORE_ID"
    printf '%-16s %s\n' "Artifact" "$FILE"
    printf '%-16s %s\n' "Source ref" "$SOURCE_REF"
    printf '%-16s %s\n' "Target SHA256" "$EXPECTED_SHA"
    printf '%-16s %s\n' "Live SHA256" "$live_sha"
    printf '%-16s %s\n' "State" "$STATE"
    echo

    if [ -f "$LIVE" ] && cmp -s "$LIVE" "$ARTIFACT"; then
        echo "[OK] Runtime already matches this KNOWN_GOOD target; rollback would be a no-op."
    elif [ -f "$LIVE" ]; then
        diff -u --label "LIVE:${FILE}" --label "KNOWN_GOOD:${RESTORE_ID}" "$LIVE" "$ARTIFACT" || true
    else
        diff -u --label /dev/null --label "KNOWN_GOOD:${RESTORE_ID}" /dev/null "$ARTIFACT" || true
    fi
}

append_ledger() {
    local old_sha="$1" new_sha="$2" backup="$3"
    mkdir -p "$LOG_DIR" || return 1
    touch "$LEDGER" || return 1
    printf 'v1\t%s\t%s\t%s\tROLLBACK\t%s\t%s\t%s\t%s\tSUCCESS\n' \
        "$(date --iso-8601=seconds)" "$SOURCE_REF" "$FILE" "$old_sha" "$new_sha" "$backup" "$(id -un)" >> "$LEDGER"
}

execute_rollback() {
    local id="$1" old_sha="MISSING" new_sha backup
    require_root
    resolve_point "$id" || exit 1
    preview "$id" || exit 1

    if [ -f "$LIVE" ] && cmp -s "$LIVE" "$ARTIFACT"; then
        echo "[OK] Runtime already equals the selected KNOWN_GOOD artifact."
        exit 0
    fi

    echo
    read -r -p "Type 'yes' to replace runtime with this curated KNOWN_GOOD artifact: " confirm
    [ "$confirm" = "yes" ] || { echo "[INFO] Rollback cancelled."; exit 0; }

    mkdir -p "$BACKUP_DIR" "$LIVE_DIR" || exit 1
    backup="${BACKUP_DIR}/${FILE}.$(date '+%Y%m%d_%H%M%S').pre-rollback"

    if [ -f "$LIVE" ]; then
        old_sha="$(sha256sum "$LIVE" | awk '{print $1}')"
        cp -a -- "$LIVE" "$backup" || { echo "[ERROR] Failed to preserve current runtime artifact." >&2; exit 1; }
    else
        backup="NONE"
    fi

    install -m 0755 -- "$ARTIFACT" "$LIVE" || { echo "[ERROR] Rollback installation failed." >&2; exit 1; }

    case "$FILE" in
        *.sh) bash -n "$LIVE" || { echo "[ERROR] Restored shell artifact failed syntax validation." >&2; exit 1; } ;;
        *.py) python3 -m py_compile "$LIVE" || { echo "[ERROR] Restored Python artifact failed syntax validation." >&2; exit 1; } ;;
    esac

    new_sha="$(sha256sum "$LIVE" | awk '{print $1}')"
    [ "$new_sha" = "$EXPECTED_SHA" ] || { echo "[ERROR] Restored checksum does not match curated target." >&2; exit 1; }

    append_ledger "$old_sha" "$new_sha" "$backup" || {
        echo "[ERROR] Rollback completed but provenance ledger append failed. Review immediately." >&2
        exit 1
    }

    echo "[OK] Rollback completed to curated restore point: $RESTORE_ID"
    echo "[OK] SHA256: $new_sha"
    echo "[INFO] Perform the script-specific runtime smoke test before declaring recovery complete."
}

usage() {
    cat <<EOF
Usage:
  $0 list
  $0 preview <restore-id>
  $0 rollback <restore-id>

Only artifacts explicitly curated as KNOWN_GOOD are eligible.
EOF
}

case "${1:-}" in
    list)     list_points ;;
    preview)  [ "$#" -eq 2 ] || { usage; exit 2; }; preview "$2" ;;
    rollback) [ "$#" -eq 2 ] || { usage; exit 2; }; execute_rollback "$2" ;;
    *) usage; exit 2 ;;
esac
