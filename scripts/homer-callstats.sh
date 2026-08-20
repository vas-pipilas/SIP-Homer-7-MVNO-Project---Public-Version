#!/bin/bash
# =============================================================================
# homer-callstats.sh — sanitized portfolio edition
#
# Hourly SIP quality analytics for a two-site Homer 7 deployment.
# Demonstrates:
#   * ASR derived from INVITE -> 200/INVITE outcomes
#   * explicit exclusion accounting for service/announcement traffic
#   * PDD/CST timing from correlated SIP messages
#   * per-node and per-tier rollups
#   * fallback to the latest closed hour containing data
#
# All identities, capture IDs, database names and paths are fictionalized.
# Credentials are sourced from a local file that is intentionally not in Git.
# =============================================================================

set -u

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="sip_capture"
DB_USER="sip_monitor"
DB_TIMEOUT=60
CRED_FILE="/etc/sip-homer-toolkit/db.env"
LOG_DIR="/var/log/sip-homer-toolkit"
LOG_FILE="${LOG_DIR}/callstats.log"
LINES_FILE="${LOG_FILE}.lines"
FALLBACK_MAX_HOURS=6

if [ -r "$CRED_FILE" ]; then
    # Expected variable: SIP_MONITOR_PGPASSWORD
    # shellcheck disable=SC1090
    source "$CRED_FILE"
fi

if [ -n "${SIP_MONITOR_PGPASSWORD:-}" ]; then
    export PGPASSWORD="$SIP_MONITOR_PGPASSWORD"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" "$LINES_FILE" 2>/dev/null || true
PRE_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)

log() { printf '%b\n' "$1" >> "$LOG_FILE"; }
section() {
    log ""
    log "${CYAN}============================================================${NC}"
    log "${CYAN}${BOLD}$1${NC}"
    log "${CYAN}============================================================${NC}"
}

db_query() {
    timeout "$DB_TIMEOUT" psql \
        -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --pset pager=off -t -A -F'|' -c "$1" 2>/dev/null
}

node_name() {
    case "$1" in
        11) echo "EDGE-A1" ;;
        12) echo "EDGE-A2" ;;
        21) echo "EDGE-B1" ;;
        22) echo "EDGE-B2" ;;
        31) echo "APP-A1" ;;
        32) echo "APP-A2" ;;
        41) echo "APP-B1" ;;
        42) echo "APP-B2" ;;
        *)  echo "NODE-$1" ;;
    esac
}

tier_name() {
    case "$1" in
        11|12|21|22) echo "EDGE" ;;
        31|32|41|42) echo "APP" ;;
        *) echo "OTHER" ;;
    esac
}

make_bar() {
    awk -v v="$1" -v m="$2" -v w="${3:-30}" 'BEGIN {
        if (m <= 0) { print ""; exit }
        n=int((v/m)*w); if(n<0)n=0; if(n>w)n=w;
        for(i=0;i<n;i++) printf "#";
        printf "\n";
    }'
}

# Find the latest closed hour that contains INVITEs. This avoids reporting a
# misleading empty hour when ingestion is a few minutes behind wall clock.
CURRENT_HOUR=$(date -d "$(date '+%Y-%m-%d %H:00:00')" +%s)
WINDOW_START=""; WINDOW_END=""; FALLBACK_USED=0
for offset in $(seq 1 $((FALLBACK_MAX_HOURS + 1))); do
    candidate_end=$(date -d "@$((CURRENT_HOUR - offset*3600))" '+%Y-%m-%d %H:%M:%S')
    candidate_start=$(date -d "@$((CURRENT_HOUR - (offset+1)*3600))" '+%Y-%m-%d %H:%M:%S')
    count=$(db_query "SELECT COUNT(*) FROM hep_proto_1_call WHERE data_header->>'method'='INVITE' AND create_date >= '${candidate_start}' AND create_date < '${candidate_end}';")
    if [[ "${count:-0}" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
        WINDOW_START="$candidate_start"
        WINDOW_END="$candidate_end"
        FALLBACK_USED=$((offset - 1))
        break
    fi
done

section "CALL QUALITY — ${WINDOW_START:-NO DATA} -> ${WINDOW_END:-NO DATA}"
if [ -z "$WINDOW_START" ]; then
    log "${RED}[ERROR] No INVITE data found in the fallback window.${NC}"
    exit 1
fi
if [ "$FALLBACK_USED" -gt 0 ]; then
    log "${YELLOW}[WARN] Ingestion fallback used: ${FALLBACK_USED} hour(s) earlier than the primary closed hour.${NC}"
fi

# Subscriber-facing ASR. The public example treats dial strings matching a
# normal E.164-like shape as subscriber traffic and reports excluded service
# traffic separately so filtering remains auditable rather than invisible.
ASR_ROWS=$(db_query "
WITH invites AS (
    SELECT DISTINCT ON (sid, (protocol_header->>'captureId'))
        sid,
        (protocol_header->>'captureId')::int AS node_id,
        COALESCE(data_header->>'ruri_user','') ~ '^\\+?[0-9]{9,15}$' AS subscriber_traffic
    FROM hep_proto_1_call
    WHERE data_header->>'method'='INVITE'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    ORDER BY sid, (protocol_header->>'captureId'), create_date
), answered AS (
    SELECT DISTINCT sid
    FROM hep_proto_1_call
    WHERE data_header->>'method'='200'
      AND COALESCE(data_header->>'cseq','') ILIKE '%INVITE%'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
)
SELECT
    i.node_id,
    COUNT(*) FILTER (WHERE subscriber_traffic),
    COUNT(*) FILTER (WHERE subscriber_traffic AND a.sid IS NOT NULL),
    ROUND(100.0 * COUNT(*) FILTER (WHERE subscriber_traffic AND a.sid IS NOT NULL)
          / NULLIF(COUNT(*) FILTER (WHERE subscriber_traffic),0), 2),
    COUNT(*) FILTER (WHERE NOT subscriber_traffic)
FROM invites i
LEFT JOIN answered a USING (sid)
GROUP BY i.node_id
ORDER BY i.node_id;")

log ""
log "${MAGENTA}${BOLD}ASR PER CAPTURE NODE${NC}"
printf_header=$(printf '%-12s %9s %9s %8s %9s %s' "NODE" "INVITES" "ANSWERED" "ASR" "EXCLUDED" "GRAPH")
log "$printf_header"

EDGE_INV=0; EDGE_ANS=0; APP_INV=0; APP_ANS=0
while IFS='|' read -r node invites answered asr excluded; do
    [ -z "$node" ] && continue
    name=$(node_name "$node")
    tier=$(tier_name "$node")
    bar=$(make_bar "${asr:-0}" 100 28)
    log "$(printf '%-12s %9s %9s %7s%% %9s %s' "$name" "${invites:-0}" "${answered:-0}" "${asr:-0}" "${excluded:-0}" "$bar")"
    case "$tier" in
        EDGE) EDGE_INV=$((EDGE_INV + invites)); EDGE_ANS=$((EDGE_ANS + answered)) ;;
        APP)  APP_INV=$((APP_INV + invites));  APP_ANS=$((APP_ANS + answered)) ;;
    esac
done <<< "$ASR_ROWS"

calc_pct() { awk -v a="$1" -v t="$2" 'BEGIN{if(t>0)printf "%.2f",100*a/t;else printf "0.00"}'; }
log ""
log "${CYAN}${BOLD}TIER ROLLUP${NC}"
log "$(printf '%-12s %9s %9s %8s' "EDGE" "$EDGE_INV" "$EDGE_ANS" "$(calc_pct "$EDGE_ANS" "$EDGE_INV")%")"
log "$(printf '%-12s %9s %9s %8s' "APP"  "$APP_INV"  "$APP_ANS"  "$(calc_pct "$APP_ANS" "$APP_INV")%")"

# PDD and CST are calculated from SIP timestamps for each dialog at each node.
# PDD: INVITE -> first 180/183. CST: INVITE -> final 200/INVITE.
TIMING_ROWS=$(db_query "
WITH msgs AS (
    SELECT sid,
           (protocol_header->>'captureId')::int AS node_id,
           create_date,
           data_header->>'method' AS method,
           COALESCE(data_header->>'cseq','') AS cseq
    FROM hep_proto_1_call
    WHERE create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
), per_call AS (
    SELECT sid,node_id,
           MIN(create_date) FILTER (WHERE method='INVITE') AS invite_ts,
           MIN(create_date) FILTER (WHERE method IN ('180','183')) AS progress_ts,
           MIN(create_date) FILTER (WHERE method='200' AND cseq ILIKE '%INVITE%') AS answer_ts
    FROM msgs
    GROUP BY sid,node_id
)
SELECT node_id,
       ROUND(AVG(EXTRACT(EPOCH FROM (progress_ts-invite_ts)))::numeric,3) FILTER (WHERE progress_ts IS NOT NULL),
       ROUND(AVG(EXTRACT(EPOCH FROM (answer_ts-invite_ts)))::numeric,3) FILTER (WHERE answer_ts IS NOT NULL)
FROM per_call
WHERE invite_ts IS NOT NULL
GROUP BY node_id
ORDER BY node_id;")

log ""
log "${MAGENTA}${BOLD}SIGNALLING TIMING${NC}"
log "$(printf '%-12s %12s %12s' "NODE" "AVG PDD(s)" "AVG CST(s)")"
while IFS='|' read -r node pdd cst; do
    [ -z "$node" ] && continue
    log "$(printf '%-12s %12s %12s' "$(node_name "$node")" "${pdd:-n/a}" "${cst:-n/a}")"
done <<< "$TIMING_ROWS"

log ""
log "Definitions: ASR=answered INVITEs / subscriber-facing INVITEs; PDD=INVITE -> 180/183; CST=INVITE -> 200/INVITE."
log "The excluded-traffic column is intentionally visible to prevent hidden denominator changes."
log "${CYAN}============================================================${NC}"

POST_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "$PRE_LINES")
echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"
tail -n "$((POST_LINES - PRE_LINES))" "$LOG_FILE"
