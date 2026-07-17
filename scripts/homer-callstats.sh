#!/bin/bash
# =============================================================================
# homer-callstats.sh
# MVNO call-quality statistics — ASR / PDD / CST / Network-failure-rate per node
# Includes per-site (Site A/Site B) and per-category (FACE/FARM) rollups.
# Reports on the most recently CLOSED hour (accounts for import lag):
#   run at HH:10  ->  reports window (HH-2):00 to (HH-1):00
# Logs to /var/log/homer/homer-callstats.log
# Writes the exact line count of THIS run's output to a sidecar file
# (homer-callstats.log.lines) so the 'callstats' alias can tail precisely
# that run's output instead of guessing a fixed number.
# =============================================================================

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="homer_data"
DB_USER="homer_monitor"
DB_TIMEOUT=60
LOG_FILE="/var/log/homer/homer-callstats.log"
LINES_FILE="${LOG_FILE}.lines"

if ! source /etc/homer/homer-db-credentials.env 2>/tmp/homer-cred-err.$$; then
    echo "[FATAL] Cannot read /etc/homer/homer-db-credentials.env -- $(cat /tmp/homer-cred-err.$$ 2>/dev/null)" >&2
    echo "[FATAL] Check you are a member of the homer-monitor group: groups \$(whoami)" >&2
    rm -f /tmp/homer-cred-err.$$
    exit 1
fi
rm -f /tmp/homer-cred-err.$$
if [ -z "$HOMER_MONITOR_PGPASSWORD" ]; then
    echo "[FATAL] HOMER_MONITOR_PGPASSWORD is empty after sourcing credentials file -- check its contents." >&2
    exit 1
fi
export PGPASSWORD="$HOMER_MONITOR_PGPASSWORD"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging setup (per project convention) ---------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" 2>/dev/null; chmod 666 "$LOG_FILE" 2>/dev/null
touch "$LINES_FILE" 2>/dev/null; chmod 666 "$LINES_FILE" 2>/dev/null

PRE_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)

log() { printf '%b\n' "$1" >> "$LOG_FILE"; }
separator() { log "${CYAN}============================================================${NC}"; }
section() { log ""; separator; log "${CYAN}${BOLD}=== $1 ===${NC}"; separator; }
explain() { log "${BLUE}$1${NC}"; }

db_query() {
    timeout "$DB_TIMEOUT" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --pset pager=off -t -A -F'|' -c "$1" 2>/dev/null
}

# --- Reporting window: the hour before last (epoch-based, avoids date -d bugs)
CURRENT_HOUR_EPOCH=$(date -d "$(date +"%Y-%m-%d %H:00:00")" +%s)
WINDOW_END=$(date -d "@$((CURRENT_HOUR_EPOCH - 3600))" +"%Y-%m-%d %H:%M:%S")
WINDOW_START=$(date -d "@$((CURRENT_HOUR_EPOCH - 7200))" +"%Y-%m-%d %H:%M:%S")
WINDOW_LABEL="${WINDOW_START} -> ${WINDOW_END}"

# --- Node name / site / category lookups ------------------------------------
node_name() {
    case "$1" in
        101) echo "EDGEVM-A1" ;;
        102) echo "EDGEVM-A2" ;;
        201) echo "EDGEVM-B1" ;;
        202) echo "EDGEVM-B2" ;;
        301) echo "APPVM-A1" ;;
        302) echo "APPVM-A2" ;;
        401) echo "APPVM-B1" ;;
        402) echo "APPVM-B2" ;;
        *) echo "node-$1" ;;
    esac
}
site_of() {
    case "$1" in
        101|102|301|302) echo "Site A" ;;
        201|202|401|402) echo "Site B" ;;
        *) echo "Unknown" ;;
    esac
}
category_of() {
    case "$1" in
        101|102|201|202) echo "FACE" ;;
        301|302|401|402) echo "FARM" ;;
        *) echo "Unknown" ;;
    esac
}

# --- ASCII bar generator -----------------------------------------------------
make_bar() {
    local value="$1" max="$2" width="${3:-40}"
    awk -v v="$value" -v m="$max" -v w="$width" 'BEGIN {
        if (m <= 0) { print ""; exit }
        len = int((v/m)*w)
        if (len < 0) len = 0
        if (len > w) len = w
        bar = ""
        for (i=0;i<len;i++) bar = bar "#"
        print bar
    }'
}

# --- Stats helpers -----------------------------------------------------------
calc_median() {
    local vals="$1"
    awk -v vals="$vals" 'BEGIN {
        n = split(vals, a, " ")
        if (n==0) { print "0.00"; exit }
        for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (a[i]+0 > a[j]+0) { t=a[i]; a[i]=a[j]; a[j]=t }
        if (n%2==1) printf "%.2f", a[(n+1)/2]
        else printf "%.2f", (a[n/2]+a[n/2+1])/2
    }'
}
weighted_avg() {
    local vals="$1" weights="$2"
    awk -v vals="$vals" -v weights="$weights" 'BEGIN{
        nv=split(vals,V," "); nw=split(weights,W," ")
        num=0; den=0
        for(i=1;i<=nv;i++){ num+=V[i]*W[i]; den+=W[i] }
        if(den>0) printf "%.3f", num/den; else printf "0.000"
    }'
}
color_high() {
    local val="$1" good="$2" warn="$3"
    if awk "BEGIN{exit !($val>=$good)}"; then printf '%s' "$GREEN"
    elif awk "BEGIN{exit !($val>=$warn)}"; then printf '%s' "$YELLOW"
    else printf '%s' "$RED"; fi
}
color_low() {
    local val="$1" good="$2" warn="$3"
    if awk "BEGIN{exit !($val<=$good)}"; then printf '%s' "$GREEN"
    elif awk "BEGIN{exit !($val<=$warn)}"; then printf '%s' "$YELLOW"
    else printf '%s' "$RED"; fi
}

section "CALL STATISTICS — WINDOW: ${WINDOW_LABEL} (run at $(date '+%Y-%m-%d %H:%M:%S'))"

# =============================================================================
# 1. ASR PER NODE
# =============================================================================
log ""
log "${CYAN}${BOLD}--- ANSWER SEIZURE RATIO (ASR) PER NODE ---${NC}"
explain "ASR = % of INVITE attempts that received a genuine 200 OK answer (matched via CSeq, not just any 200). Higher is better. Typical healthy range: ~40-70%. Excludes internal service/announcement-platform destinations (voicemail/IVR routing codes -- e.g. ruri_user like 'C0020022017' rather than a real MSISDN) from both invites and answered counts, since these structurally almost never receive a 200 OK and would otherwise distort ASR. Confirmed via a 3-day investigation: FARM nodes carry roughly 2.7x the proportional share of this traffic that FACE nodes do, which was the entire cause of a persistent 5-7 point FACE-vs-FARM ASR gap -- once excluded, both tiers match to within hundredths of a point. Excluded volume is NOT hidden -- see the separate table below."
log ""

ASR_ROWS=$(db_query "
WITH all_invites AS (
    SELECT
        sid,
        (protocol_header->>'captureId')::int AS node_id,
        (regexp_replace(data_header->>'ruri_user', '^[A-Z][0-9]{2}', '') ~ '^\+?[0-9]{9,}\$') AS is_real_msisdn
    FROM hep_proto_1_call
    WHERE data_header->>'method' = 'INVITE'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
),
distinct_invites AS (
    SELECT sid, node_id, bool_or(is_real_msisdn) AS is_real_msisdn
    FROM all_invites
    GROUP BY sid, node_id
),
answered AS (
    SELECT DISTINCT sid
    FROM hep_proto_1_call
    WHERE data_header->>'method' = '200'
      AND data_header->>'cseq' LIKE '%INVITE%'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
)
SELECT
    di.node_id,
    COUNT(*) FILTER (WHERE di.is_real_msisdn) AS invites,
    COUNT(*) FILTER (WHERE di.is_real_msisdn AND a.sid IS NOT NULL) AS answered,
    ROUND(100.0 * COUNT(*) FILTER (WHERE di.is_real_msisdn AND a.sid IS NOT NULL) /
          NULLIF(COUNT(*) FILTER (WHERE di.is_real_msisdn), 0), 2) AS asr_pct,
    COUNT(*) FILTER (WHERE NOT di.is_real_msisdn) AS excluded
FROM distinct_invites di
LEFT JOIN answered a ON a.sid = di.sid
GROUP BY di.node_id
ORDER BY di.node_id;")

if [ -z "$ASR_ROWS" ]; then
    log "  (no data for this window)"
else
    log "$(printf "%-16s %8s %10s %8s %s" "NODE" "INVITES" "ANSWERED" "ASR%" "GRAPH")"

    ATH_INV=0; ATH_ANS=0; THS_INV=0; THS_ANS=0
    ATH_VALS=""; THS_VALS=""; FACE_VALS=""; FARM_VALS=""
    declare -A EXCLUDED_BY_NODE
    EXCLUDED_TOTAL=0

    while IFS='|' read -r node_id invites answered asr_pct excluded; do
        [ -z "$node_id" ] && continue
        name=$(node_name "$node_id")
        bar=$(make_bar "${asr_pct:-0}" 100 40)
        COLOR=$(color_high "${asr_pct:-0}" 60 40)
        NAME_F=$(printf "%-16s" "$name")
        INV_F=$(printf "%8s" "${invites:-0}")
        ANS_F=$(printf "%10s" "${answered:-0}")
        PCT_F=$(printf "%7s%%" "${asr_pct:-0.00}")
        log "${NAME_F} ${INV_F} ${ANS_F} ${COLOR}${PCT_F}${NC} ${bar}"

        EXCLUDED_BY_NODE[$node_id]=${excluded:-0}
        EXCLUDED_TOTAL=$((EXCLUDED_TOTAL + ${excluded:-0}))

        site=$(site_of "$node_id"); cat=$(category_of "$node_id")
        case "$site" in
            "Site A") ATH_INV=$((ATH_INV+invites)); ATH_ANS=$((ATH_ANS+answered)); ATH_VALS="$ATH_VALS $asr_pct" ;;
            "Site B") THS_INV=$((THS_INV+invites)); THS_ANS=$((THS_ANS+answered)); THS_VALS="$THS_VALS $asr_pct" ;;
        esac
        case "$cat" in
            FACE) FACE_VALS="$FACE_VALS $asr_pct" ;;
            FARM) FARM_VALS="$FARM_VALS $asr_pct" ;;
        esac
    done <<< "$ASR_ROWS"

    log ""
    log "${MAGENTA}${BOLD}-- EXCLUDED INVITES (service/announcement destinations, not counted above) --${NC}"
    log "$(printf "%-16s %10s" "NODE" "EXCLUDED")"
    for node_id in "${!EXCLUDED_BY_NODE[@]}"; do
        echo "$node_id|${EXCLUDED_BY_NODE[$node_id]}"
    done | sort -t'|' -k1,1n | while IFS='|' read -r node_id excluded; do
        name=$(node_name "$node_id")
        log "$(printf "%-16s %10s" "$name" "$excluded")"
    done
    log "$(printf "%-16s %10s" "TOTAL" "$EXCLUDED_TOTAL")"

    ATH_AVG=$(awk -v a="$ATH_ANS" -v i="$ATH_INV" 'BEGIN{if(i+0>0) printf "%.2f", 100*a/i; else printf "0.00"}')
    THS_AVG=$(awk -v a="$THS_ANS" -v i="$THS_INV" 'BEGIN{if(i+0>0) printf "%.2f", 100*a/i; else printf "0.00"}')
    ATH_MED=$(calc_median "$ATH_VALS")
    THS_MED=$(calc_median "$THS_VALS")
    FACE_MED=$(calc_median "$FACE_VALS")
    FARM_MED=$(calc_median "$FARM_VALS")

    log ""
    log "${MAGENTA}${BOLD}-- BY SITE (weighted avg = true combined ASR, median = across that site's nodes) --${NC}"
    log "$(printf "%-14s %18s %24s" "SITE" "AVG %(weighted)" "MEDIAN %(across nodes)")"
    log "$(printf "%-14s %17s%% %23s%%" "Site A" "$ATH_AVG" "$ATH_MED")"
    log "$(printf "%-14s %17s%% %23s%%" "Site B" "$THS_AVG" "$THS_MED")"
    log ""
    log "${MAGENTA}${BOLD}-- BY NODE CATEGORY (median across that category's nodes) --${NC}"
    log "$(printf "%-14s %24s" "CATEGORY" "MEDIAN %(across nodes)")"
    log "$(printf "%-14s %23s%%" "FACE" "$FACE_MED")"
    log "$(printf "%-14s %23s%%" "FARM" "$FARM_MED")"
fi

# =============================================================================
# 2. PDD PER NODE
# =============================================================================
log ""
log "${CYAN}${BOLD}--- POST-DIAL DELAY (PDD) PER NODE ---${NC}"
explain "PDD = time from INVITE to the first provisional/answer response (180/183/200). Pure network/signaling latency, not affected by human ring time. Lower is better."
log ""

PDD_ROWS=$(db_query "
WITH invites AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS invite_time
    FROM hep_proto_1_call
    WHERE data_header->>'method' = 'INVITE'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    GROUP BY sid, node_id
),
first_response AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS resp_time
    FROM hep_proto_1_call
    WHERE data_header->>'method' IN ('180','183','200')
      AND data_header->>'cseq' LIKE '%INVITE%'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    GROUP BY sid, node_id
)
SELECT i.node_id,
       COUNT(*) AS samples,
       ROUND(AVG(EXTRACT(EPOCH FROM (r.resp_time - i.invite_time)))::numeric, 3) AS avg_pdd,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (r.resp_time - i.invite_time)))::numeric, 3) AS p95_pdd
FROM invites i
JOIN first_response r ON i.sid = r.sid AND i.node_id = r.node_id
WHERE r.resp_time > i.invite_time
GROUP BY i.node_id
ORDER BY i.node_id;")

if [ -z "$PDD_ROWS" ]; then
    log "  (no data for this window)"
else
    MAX_PDD=$(echo "$PDD_ROWS" | awk -F'|' '{if($3+0>m)m=$3+0}END{print (m>0?m:1)}')
    log "$(printf "%-16s %8s %10s %10s %s" "NODE" "SAMPLES" "AVG(s)" "P95(s)" "GRAPH (avg, scaled to slowest node)")"

    ATH_AVGS=""; ATH_SAMPLES=""; THS_AVGS=""; THS_SAMPLES=""
    ATH_VALS=""; THS_VALS=""; FACE_VALS=""; FARM_VALS=""

    while IFS='|' read -r node_id samples avg_pdd p95_pdd; do
        [ -z "$node_id" ] && continue
        name=$(node_name "$node_id")
        bar=$(make_bar "${avg_pdd:-0}" "$MAX_PDD" 40)
        COLOR=$(color_low "${avg_pdd:-0}" 3 5)
        NAME_F=$(printf "%-16s" "$name")
        SAMP_F=$(printf "%8s" "${samples:-0}")
        AVG_F=$(printf "%10s" "${avg_pdd:-0.000}")
        P95_F=$(printf "%10s" "${p95_pdd:-0.000}")
        log "${NAME_F} ${SAMP_F} ${COLOR}${AVG_F}${NC} ${P95_F} ${bar}"

        site=$(site_of "$node_id"); cat=$(category_of "$node_id")
        case "$site" in
            "Site A") ATH_AVGS="$ATH_AVGS $avg_pdd"; ATH_SAMPLES="$ATH_SAMPLES $samples"; ATH_VALS="$ATH_VALS $avg_pdd" ;;
            "Site B") THS_AVGS="$THS_AVGS $avg_pdd"; THS_SAMPLES="$THS_SAMPLES $samples"; THS_VALS="$THS_VALS $avg_pdd" ;;
        esac
        case "$cat" in
            FACE) FACE_VALS="$FACE_VALS $avg_pdd" ;;
            FARM) FARM_VALS="$FARM_VALS $avg_pdd" ;;
        esac
    done <<< "$PDD_ROWS"

    ATH_WAVG=$(weighted_avg "$ATH_AVGS" "$ATH_SAMPLES")
    THS_WAVG=$(weighted_avg "$THS_AVGS" "$THS_SAMPLES")
    ATH_MED=$(calc_median "$ATH_VALS")
    THS_MED=$(calc_median "$THS_VALS")
    FACE_MED=$(calc_median "$FACE_VALS")
    FARM_MED=$(calc_median "$FARM_VALS")

    log ""
    log "${MAGENTA}${BOLD}-- BY SITE (weighted avg = exact grand mean using sample counts, median = across that site's nodes) --${NC}"
    log "$(printf "%-14s %16s %20s" "SITE" "AVG(s,weighted)" "MEDIAN(s,across nodes)")"
    log "$(printf "%-14s %16s %20s" "Site A" "$ATH_WAVG" "$ATH_MED")"
    log "$(printf "%-14s %16s %20s" "Site B" "$THS_WAVG" "$THS_MED")"
    log ""
    log "${MAGENTA}${BOLD}-- BY NODE CATEGORY (median across that category's nodes) --${NC}"
    log "$(printf "%-14s %22s" "CATEGORY" "MEDIAN(s,across nodes)")"
    log "$(printf "%-14s %22s" "FACE" "$FACE_MED")"
    log "$(printf "%-14s %22s" "FARM" "$FARM_MED")"
fi

# =============================================================================
# 3. CST — CALL SETUP TIME BUCKETS (rows=bucket, columns=node)
# =============================================================================
log ""
log "${CYAN}${BOLD}--- CALL SETUP TIME (CST) BUCKETS ---${NC}"
explain "CST = time from INVITE to actual answer (200 OK). Includes human ring/pickup time, so most answered calls naturally land in 5-10s or >10s — this is expected, not a fault."
log ""

CST_ROWS=$(db_query "
WITH invites AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS invite_time
    FROM hep_proto_1_call
    WHERE data_header->>'method' = 'INVITE'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    GROUP BY sid, node_id
),
answers AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS answer_time
    FROM hep_proto_1_call
    WHERE data_header->>'method' = '200'
      AND data_header->>'cseq' LIKE '%INVITE%'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    GROUP BY sid, node_id
),
setup_times AS (
    SELECT i.node_id, EXTRACT(EPOCH FROM (a.answer_time - i.invite_time)) AS setup_sec
    FROM invites i JOIN answers a ON i.sid = a.sid AND i.node_id = a.node_id
    WHERE a.answer_time > i.invite_time
),
bucketed AS (
    SELECT node_id,
        CASE WHEN setup_sec < 1 THEN '<1s' WHEN setup_sec < 3 THEN '1-3s'
             WHEN setup_sec < 5 THEN '3-5s' WHEN setup_sec < 10 THEN '5-10s'
             ELSE '>10s' END AS bucket
    FROM setup_times
)
SELECT node_id, bucket, COUNT(*) FROM bucketed GROUP BY node_id, bucket;")

if [ -z "$CST_ROWS" ]; then
    log "  (no data for this window)"
else
    CST_TABLE=$(echo "$CST_ROWS" | awk -F'|' '
    BEGIN {
        name[101]="EDGEVM-A1"; name[102]="EDGEVM-A2"
        name[201]="EDGEVM-B1"; name[202]="EDGEVM-B2"
        name[301]="APPVM-A1"; name[302]="APPVM-A2"
        name[401]="APPVM-B1"; name[402]="APPVM-B2"
    }
    {
        node=$1; bucket=$2; cnt=$3
        if (!(node in seen_node)) { seen_node[node]=1; nodes[++nn]=node }
        data[bucket,node]=cnt
        totals[bucket]+=cnt
    }
    END {
        for (i=1;i<=nn;i++) for (j=i+1;j<=nn;j++) if (nodes[i]+0 > nodes[j]+0) { t=nodes[i]; nodes[i]=nodes[j]; nodes[j]=t }
        hdr = sprintf("%-8s", "BUCKET")
        for (i=1;i<=nn;i++) {
            label = (nodes[i] in name) ? name[nodes[i]] : ("node-" nodes[i])
            hdr = hdr sprintf(" %14s", label)
        }
        hdr = hdr sprintf(" %10s", "TOTAL")
        print hdr
        blist[1]="<1s"; blist[2]="1-3s"; blist[3]="3-5s"; blist[4]="5-10s"; blist[5]=">10s"
        for (b=1;b<=5;b++) {
            bname=blist[b]
            line = sprintf("%-8s", bname)
            for (i=1;i<=nn;i++) {
                v = data[bname,nodes[i]]+0
                line = line sprintf(" %14d", v)
            }
            line = line sprintf(" %10d", totals[bname]+0)
            print line
        }
    }')
    log "$CST_TABLE"

    log ""
    explain "The block below computes true average/median setup time (seconds) directly from raw calls grouped by site/category — not derived from the buckets above."
    CST_GROUP_ROWS=$(db_query "
    WITH invites AS (
        SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS invite_time
        FROM hep_proto_1_call
        WHERE data_header->>'method' = 'INVITE'
          AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
        GROUP BY sid, node_id
    ),
    answers AS (
        SELECT sid, (protocol_header->>'captureId')::int AS node_id, MIN(create_date) AS answer_time
        FROM hep_proto_1_call
        WHERE data_header->>'method' = '200'
          AND data_header->>'cseq' LIKE '%INVITE%'
          AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
        GROUP BY sid, node_id
    ),
    setup_times AS (
        SELECT i.node_id, EXTRACT(EPOCH FROM (a.answer_time - i.invite_time)) AS setup_sec
        FROM invites i JOIN answers a ON i.sid = a.sid AND i.node_id = a.node_id
        WHERE a.answer_time > i.invite_time
    )
    SELECT 'SITE' AS grp_type, site AS grp_name, samples, avg_sec, median_sec FROM (
        SELECT CASE WHEN node_id IN (101,102,301,302) THEN 'Site A'
                    WHEN node_id IN (201,202,401,402) THEN 'Site B' END AS site,
               COUNT(*) AS samples,
               ROUND(AVG(setup_sec)::numeric,3) AS avg_sec,
               ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY setup_sec)::numeric,3) AS median_sec
        FROM setup_times GROUP BY site
    ) s
    UNION ALL
    SELECT 'CATEGORY', category, samples, avg_sec, median_sec FROM (
        SELECT CASE WHEN node_id IN (101,102,201,202) THEN 'FACE'
                    WHEN node_id IN (301,302,401,402) THEN 'FARM' END AS category,
               COUNT(*) AS samples,
               ROUND(AVG(setup_sec)::numeric,3) AS avg_sec,
               ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY setup_sec)::numeric,3) AS median_sec
        FROM setup_times GROUP BY category
    ) c
    ORDER BY grp_type, grp_name;")

    if [ -n "$CST_GROUP_ROWS" ]; then
        log ""
        log "$(printf "%-10s %-14s %8s %10s %10s" "TYPE" "GROUP" "SAMPLES" "AVG(s)" "MEDIAN(s)")"
        while IFS='|' read -r grp_type grp_name samples avg_sec median_sec; do
            [ -z "$grp_type" ] && continue
            log "$(printf "%-10s %-14s %8s %10s %10s" "$grp_type" "$grp_name" "${samples:-0}" "${avg_sec:-0.000}" "${median_sec:-0.000}")"
        done <<< "$CST_GROUP_ROWS"
    fi
fi

# =============================================================================
# 4. NETWORK-SIDE FAILURE RATE (503/408, first-error-only) PER NODE
# =============================================================================
log ""
log "${CYAN}${BOLD}--- NETWORK-SIDE FAILURE RATE (503/408, first error only) PER NODE ---${NC}"
explain "% of INVITE attempts whose FIRST final response was 503/408 — these indicate infra/network problems, not subscriber behavior. This is the key SLA-watch metric. Lower is better."
log ""

NETFAIL_ROWS=$(db_query "
WITH invites AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id
    FROM hep_proto_1_call
    WHERE data_header->>'method' = 'INVITE'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
    GROUP BY sid, node_id
),
network_errors AS (
    SELECT sid, (protocol_header->>'captureId')::int AS node_id, data_header->>'method' AS method, create_date
    FROM hep_proto_1_call
    WHERE data_header->>'method' IN ('503','408')
      AND data_header->>'cseq' LIKE '%INVITE%'
      AND create_date >= '${WINDOW_START}' AND create_date < '${WINDOW_END}'
),
first_network_error AS (
    SELECT DISTINCT ON (sid, node_id) sid, node_id, method
    FROM network_errors
    ORDER BY sid, node_id, create_date ASC
)
SELECT i.node_id,
       COUNT(DISTINCT i.sid) AS invites,
       COUNT(DISTINCT fe.sid) FILTER (WHERE fe.method='503') AS first_503,
       COUNT(DISTINCT fe.sid) FILTER (WHERE fe.method='408') AS first_408,
       COUNT(DISTINCT fe.sid) AS total_failures,
       ROUND(100.0 * COUNT(DISTINCT fe.sid) / NULLIF(COUNT(DISTINCT i.sid),0), 3) AS fail_pct
FROM invites i
LEFT JOIN first_network_error fe ON i.sid = fe.sid AND i.node_id = fe.node_id
GROUP BY i.node_id
ORDER BY i.node_id;")

if [ -z "$NETFAIL_ROWS" ]; then
    log "  (no data for this window)"
else
    log "$(printf "%-16s %8s %6s %6s %8s %s" "NODE" "INVITES" "503" "408" "FAIL%" "GRAPH (scaled to 10%)")"

    ATH_INV=0; ATH_FAIL=0; THS_INV=0; THS_FAIL=0
    ATH_VALS=""; THS_VALS=""; FACE_VALS=""; FARM_VALS=""

    while IFS='|' read -r node_id invites f503 f408 total fail_pct; do
        [ -z "$node_id" ] && continue
        name=$(node_name "$node_id")
        bar=$(make_bar "${fail_pct:-0}" 10 40)
        COLOR=$(color_low "${fail_pct:-0}" 1 3)
        NAME_F=$(printf "%-16s" "$name")
        INV_F=$(printf "%8s" "${invites:-0}")
        F503_F=$(printf "%6s" "${f503:-0}")
        F408_F=$(printf "%6s" "${f408:-0}")
        PCT_F=$(printf "%7s%%" "${fail_pct:-0.000}")
        log "${NAME_F} ${INV_F} ${F503_F} ${F408_F} ${COLOR}${PCT_F}${NC} ${bar}"

        site=$(site_of "$node_id"); cat=$(category_of "$node_id")
        case "$site" in
            "Site A") ATH_INV=$((ATH_INV+invites)); ATH_FAIL=$((ATH_FAIL+total)); ATH_VALS="$ATH_VALS $fail_pct" ;;
            "Site B") THS_INV=$((THS_INV+invites)); THS_FAIL=$((THS_FAIL+total)); THS_VALS="$THS_VALS $fail_pct" ;;
        esac
        case "$cat" in
            FACE) FACE_VALS="$FACE_VALS $fail_pct" ;;
            FARM) FARM_VALS="$FARM_VALS $fail_pct" ;;
        esac
    done <<< "$NETFAIL_ROWS"

    ATH_AVG=$(awk -v f="$ATH_FAIL" -v i="$ATH_INV" 'BEGIN{if(i+0>0) printf "%.3f", 100*f/i; else printf "0.000"}')
    THS_AVG=$(awk -v f="$THS_FAIL" -v i="$THS_INV" 'BEGIN{if(i+0>0) printf "%.3f", 100*f/i; else printf "0.000"}')
    ATH_MED=$(calc_median "$ATH_VALS")
    THS_MED=$(calc_median "$THS_VALS")
    FACE_MED=$(calc_median "$FACE_VALS")
    FARM_MED=$(calc_median "$FARM_VALS")

    log ""
    log "${MAGENTA}${BOLD}-- BY SITE (weighted avg = true combined failure rate, median = across that site's nodes) --${NC}"
    log "$(printf "%-14s %18s %24s" "SITE" "AVG %(weighted)" "MEDIAN %(across nodes)")"
    log "$(printf "%-14s %17s%% %23s%%" "Site A" "$ATH_AVG" "$ATH_MED")"
    log "$(printf "%-14s %17s%% %23s%%" "Site B" "$THS_AVG" "$THS_MED")"
    log ""
    log "${MAGENTA}${BOLD}-- BY NODE CATEGORY (median across that category's nodes) --${NC}"
    log "$(printf "%-14s %24s" "CATEGORY" "MEDIAN %(across nodes)")"
    log "$(printf "%-14s %23s%%" "FACE" "$FACE_MED")"
    log "$(printf "%-14s %23s%%" "FARM" "$FARM_MED")"
fi

# =============================================================================
section "CALL STATISTICS COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
log ""

POST_LINES=$(wc -l < "$LOG_FILE")
echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"

exit 0