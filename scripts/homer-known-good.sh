#!/usr/bin/env bash
# =============================================================================
# homer-known-good.sh — sanitized portfolio edition
# Curates explicit known-good runtime artifacts for controlled recovery.
# =============================================================================

set -u

LIVE_DIR="${HOMER_LIVE_DIR:-/usr/local/bin}"
STATE_DIR="${HOMER_RECOVERY_STATE_DIR:-/var/lib/sip-homer-toolkit/known-good}"
INDEX="${STATE_DIR}/index.tsv"

require_root() {
    [ "$EUID" -eq 0 ] || { echo "[ERROR] Known-good promotion requires root." >&2; exit 1; }
}

safe_name() {
    [[ "$1" =~ ^homer-[A-Za-z0-9._-]+\.(sh|py)$ ]]
}

init_state() {
    mkdir -p "$STATE_DIR" || exit 1
    touch "$INDEX" || exit 1
    chmod 0750 "$STATE_DIR"
    chmod 0640 "$INDEX"
}

promote() {
    local name="$1" live sha short restore_id dir artifact
    require_root
    init_state
    safe_name "$name" || { echo "[ERROR] Unsupported artifact name." >&2; exit 2; }

    live="${LIVE_DIR}/${name}"
    [ -f "$live" ] || { echo "[ERROR] Runtime artifact not found: $live" >&2; exit 1; }

    case "$name" in
        *.sh) bash -n "$live" || { echo "[ERROR] Runtime syntax validation failed." >&2; exit 1; } ;;
        *.py) python3 -m py_compile "$live" || { echo "[ERROR] Runtime syntax validation failed." >&2; exit 1; } ;;
    esac

    sha="$(sha256sum "$live" | awk '{print $1}')"
    short="${HOMER_SOURCE_COMMIT:-manual-review}"
    restore_id="$(date '+%Y%m%d_%H%M%S')_${short:0:12}"
    dir="${STATE_DIR}/${restore_id}"
    artifact="${dir}/${name}"

    echo
    echo "KNOWN_GOOD PROMOTION"
    echo "------------------------------------------------------------"
    printf '%-14s %s\n' "Artifact" "$name"
    printf '%-14s %s\n' "SHA256" "$sha"
    printf '%-14s %s\n' "Source ref" "$short"
    echo
    read -r -p "Type 'yes' to curate this runtime artifact as KNOWN_GOOD: " confirm
    [ "$confirm" = "yes" ] || { echo "[INFO] Promotion cancelled."; exit 0; }

    mkdir -p "$dir" || exit 1
    cp -a -- "$live" "$artifact" || exit 1
    chmod 0550 "$artifact"

    cat > "${dir}/metadata.env" <<EOF
RESTORE_ID=${restore_id}
FILE=${name}
SOURCE_REF=${short}
SHA256=${sha}
PROMOTED_AT=$(date --iso-8601=seconds)
STATE=KNOWN_GOOD
EOF
    chmod 0440 "${dir}/metadata.env"

    printf '%s\t%s\t%s\t%s\t%s\tKNOWN_GOOD\n' \
        "$restore_id" "$name" "$short" "$sha" "$(date --iso-8601=seconds)" >> "$INDEX"

    echo "[OK] Curated restore point: $restore_id"
}

list_points() {
    init_state
    printf '%-28s %-32s %-14s %-64s %s\n' "RESTORE ID" "FILE" "SOURCE" "SHA256" "STATE"
    printf '%-28s %-32s %-14s %-64s %s\n' "----------------------------" "--------------------------------" "--------------" "----------------------------------------------------------------" "----------"
    awk -F '\t' '$6=="KNOWN_GOOD" {printf "%-28s %-32s %-14s %-64s %s\n",$1,$2,$3,$4,$6}' "$INDEX"
}

reject() {
    local restore_id="$1" tmp
    require_root
    init_state
    grep -q "^${restore_id}[[:space:]]" "$INDEX" || { echo "[ERROR] Restore point not found." >&2; exit 1; }
    tmp="$(mktemp)"
    awk -F '\t' -v OFS='\t' -v id="$restore_id" '{if ($1==id) $6="REJECTED"; print}' "$INDEX" > "$tmp"
    install -m 0640 "$tmp" "$INDEX"
    rm -f "$tmp"
    [ -f "${STATE_DIR}/${restore_id}/metadata.env" ] && sed -i 's/^STATE=.*/STATE=REJECTED/' "${STATE_DIR}/${restore_id}/metadata.env"
    echo "[OK] Restore point marked REJECTED: $restore_id"
}

usage() {
    cat <<EOF
Usage:
  $0 list
  $0 promote <homer-script.sh|py>
  $0 reject <restore-id>

This portfolio version demonstrates curated recovery points. Arbitrary historical
files are not automatically considered safe rollback targets.
EOF
}

case "${1:-}" in
    list)    list_points ;;
    promote) [ "$#" -eq 2 ] || { usage; exit 2; }; promote "$2" ;;
    reject)  [ "$#" -eq 2 ] || { usage; exit 2; }; reject "$2" ;;
    *) usage; exit 2 ;;
esac
