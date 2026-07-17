#!/bin/bash
# =============================================================================
# homer-sbc-routes.sh
#
# SBC route-prefix traffic analysis for a Homer 7 SIP monitoring platform.
# Classifies FACE(edge)<->SBC INVITEs by their routing prefix (e.g.
# "A04+3013803" -> prefix "A04"), a short code the SBC's own routing engine
# stamps onto each call to identify which carrier interconnect it came from
# or is going to. Cross-references against a known route sheet per site.
#
# Direction (FROM_SBC / TO_SBC) is derived independently from srcIp/dstIp
# matched against known edge/SBC IPs per site -- NOT from the route prefix's
# own A/B naming convention, since that's just a label, not ground truth.
#
# Prefix extraction checks TWO locations, since ported numbers carry the
# routing prefix differently than direct-routed ones:
#   1. ruri_user directly     e.g. "A02+306900000000"        (non-ported)
#   2. the rn= URI parameter  e.g. "...;npdi;rn=B21+3059..."  (ported numbers,
#      NPDI = Number Portability Dip Indicator, rn = Routing Number -- the
#      SBC performs a portability lookup and stamps the *real* destination
#      carrier onto rn= instead of the R-URI, since a ported number's
#      original prefix no longer indicates the correct carrier)
#
# TG / RL column: on FROM_SBC (A-side) rows this is the real ingress Trunk
# Group name. On TO_SBC (B-side) rows this is the egress Routing Label
# instead -- the generic "core" trunk group is the same for every outbound
# route, so the RL is the meaningful egress identifier there.
#
# NOTE on unique-call counting: this reports total INVITE counts only, no
# "unique calls" metric. On the platform this was built for, neither the raw
# SIP Call-ID nor the monitoring tool's own correlation ID turned out to be a
# safe deduplication key -- the upstream SBC's internal Call-ID counter was
# confirmed (empirically, via real traffic analysis) to occasionally reuse
# the same value for two entirely unrelated calls within the same reporting
# hour. Reporting total event counts avoids this risk entirely rather than
# silently under-counting.
#
# Reporting window: normally the most recently closed hour (accounts for
# ingestion lag). If that window has no data yet, automatically falls back
# to earlier hours one at a time, up to FALLBACK_MAX_HOURS back, and clearly
# labels the output if a fallback hour was used instead of the primary one.
#
# Logs to /var/log/homer/homer-sbc-routes.log
# Writes the exact line count of THIS run's output to a sidecar file
# (homer-sbc-routes.log.lines) so a simple alias can tail precisely that
# run's output instead of guessing a fixed number.
# =============================================================================

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="homer_data"
DB_USER="homer_monitor"
DB_TIMEOUT=60
LOG_FILE="/var/log/homer/homer-sbc-routes.log"
LINES_FILE="${LOG_FILE}.lines"
FALLBACK_MAX_HOURS=6

# Credentials are sourced from a plain env file rather than PGPASSWORD
# hardcoded in this script (keeps secrets out of version control) and
# rather than a standard .pgpass file (libpq refuses to use a .pgpass with
# group/world read permissions, which is incompatible with a credential
# meant to be shared across a team via normal Linux group permissions).
source /etc/homer/homer-db-credentials.env 2>/dev/null
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

# --- Logging setup ------------------------------------------------------------
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

route_query() {
    local w_start="$1" w_end="$2"
    db_query "
WITH face_ips (site, ip) AS (
    VALUES
    ('Site A','192.0.2.21'), ('Site A','192.0.2.22'),
    ('Site B','198.51.100.21'), ('Site B','198.51.100.22')
),
sbc_ips (site, ip) AS (
    VALUES
    ('Site A','192.0.2.45'), ('Site A','192.0.2.46'),
    ('Site B','198.51.100.45'), ('Site B','198.51.100.46')
),
route_map (site, prefix, tg_name, route_name) AS (
    VALUES
    -- ===================== SITE A — A-prefixes (ingress Trunk Group) ==========
    ('Site A','A01','TG_A_HOSTMNO_MVNO_PAL','Host MNO MVNO (onnet)'),
    ('Site A','A02','TG_A_HOSTMNO_MVNO_MET','Host MNO MVNO (offnet)'),
    ('Site A','A03','TG_A_HOSTMNO_MOB_PAL','Host MNO Mobile (onnet)'),
    ('Site A','A04','TG_A_HOSTMNO_MOB_MET','Host MNO Mobile (offnet)'),
    ('Site A','A05','TG_A_HOSTMNO_FIX_PAL','Host MNO Fixed (onnet)'),
    ('Site A','A06','TG_A_HOSTMNO_FIX_MET','Host MNO Fixed (offnet)'),
    ('Site A','A11','TG_A_FIXEDINC_1','Fixed Incumbent'),
    ('Site A','A21','TG_A_PARTNER1','Partner MNO 1'),
    ('Site A','A31','TG_A_PARTNER2_MOB','Partner MNO 2 Mobile'),
    ('Site A','A33','TG_A_PARTNER2_FIX','Partner MNO 2 Fixed'),
    ('Site A','A51','TG_A_PBX','PBX'),
    -- ===================== SITE A — B-prefixes (egress Routing Label) =========
    ('Site A','B01','RL_TO_A_HOSTMNO_MVNO','Host MNO MVNO'),
    ('Site A','B03','RL_TO_A_HOSTMNO_MOB','Host MNO Mobile'),
    ('Site A','B05','RL_TO_A_HOSTMNO_FIX','Host MNO Fixed'),
    ('Site A','B11','RL_TO_A_FIXEDINC','Fixed Incumbent'),
    ('Site A','B21','RL_TO_A_PARTNER1','Partner MNO 1'),
    ('Site A','B31','RL_TO_A_PARTNER2_MOB','Partner MNO 2 Mobile'),
    ('Site A','B33','RL_TO_A_PARTNER2_FIX','Partner MNO 2 Fixed'),
    ('Site A','B41','RL_TO_A_VCS','VCS'),
    ('Site A','B51','RL_TO_A_PBX','PBX'),

    -- ===================== SITE B — A-prefixes =================================
    ('Site B','A01','TG_B_HOSTMNO_MVNO_PAL','Host MNO MVNO (onnet)'),
    ('Site B','A02','TG_B_HOSTMNO_MVNO_MET','Host MNO MVNO (offnet)'),
    ('Site B','A03','TG_B_HOSTMNO_MOB_PAL','Host MNO Mobile (onnet)'),
    ('Site B','A04','TG_B_HOSTMNO_MOB_MET','Host MNO Mobile (offnet)'),
    ('Site B','A05','TG_B_HOSTMNO_FIX_PAL','Host MNO Fixed (onnet)'),
    ('Site B','A06','TG_B_HOSTMNO_FIX_MET','Host MNO Fixed (offnet)'),
    ('Site B','A11','TG_B_FIXEDINC_1','Fixed Incumbent'),
    ('Site B','A21','TG_B_PARTNER1','Partner MNO 1'),
    ('Site B','A31','TG_B_PARTNER2_MOB','Partner MNO 2 Mobile'),
    ('Site B','A33','TG_B_PARTNER2_FIX','Partner MNO 2 Fixed'),
    ('Site B','A51','TG_B_PBX','PBX'),
    -- ===================== SITE B — B-prefixes ==================================
    ('Site B','B01','RL_TO_B_HOSTMNO_MVNO','Host MNO MVNO'),
    ('Site B','B03','RL_TO_B_HOSTMNO_MOB','Host MNO Mobile'),
    ('Site B','B05','RL_TO_B_HOSTMNO_FIX','Host MNO Fixed'),
    ('Site B','B11','RL_TO_B_FIXEDINC','Fixed Incumbent'),
    ('Site B','B21','RL_TO_B_PARTNER1','Partner MNO 1'),
    ('Site B','B31','RL_TO_B_PARTNER2_MOB','Partner MNO 2 Mobile'),
    ('Site B','B33','RL_TO_B_PARTNER2_FIX','Partner MNO 2 Fixed'),
    ('Site B','B41','RL_TO_B_VCS','VCS'),
    ('Site B','B51','RL_TO_B_PBX','PBX')
),
face_calls AS (
    SELECT
        c.data_header->>'callid' AS callid,
        f.site,
        CASE
            WHEN c.protocol_header->>'srcIp' = s.ip AND c.protocol_header->>'dstIp' = f.ip THEN 'FROM_SBC'
            WHEN c.protocol_header->>'srcIp' = f.ip AND c.protocol_header->>'dstIp' = s.ip THEN 'TO_SBC'
        END AS direction,
        COALESCE(
            substring(c.data_header->>'ruri_user' FROM '^[A-Z][0-9]{2}'),
            substring(c.raw FROM 'rn=([A-Z][0-9]{2})')
        ) AS prefix
    FROM hep_proto_1_call c
    CROSS JOIN (SELECT 1) params
    JOIN face_ips f ON (c.protocol_header->>'srcIp' = f.ip OR c.protocol_header->>'dstIp' = f.ip)
    JOIN sbc_ips  s ON (
        (c.protocol_header->>'srcIp' = s.ip AND c.protocol_header->>'dstIp' = f.ip) OR
        (c.protocol_header->>'dstIp' = s.ip AND c.protocol_header->>'srcIp' = f.ip)
    )
    WHERE c.data_header->>'method' = 'INVITE'
      AND f.site = s.site
      AND c.create_date >= '${w_start}' AND c.create_date < '${w_end}'
)
SELECT
    fc.site,
    fc.direction,
    fc.prefix,
    rm.route_name,
    rm.tg_name,
    COUNT(*) AS total_invites
FROM face_calls fc
JOIN route_map rm ON rm.site = fc.site AND rm.prefix = fc.prefix
GROUP BY fc.site, fc.direction, fc.prefix, rm.route_name, rm.tg_name
ORDER BY fc.site, fc.direction, fc.prefix;"
}

# --- ASCII bar generator -----------------------------------------------------
make_bar() {
    local value="$1" max="$2" width="${3:-30}"
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

# =============================================================================
# Find the most recent hour with actual data, falling back earlier as needed
# =============================================================================
CURRENT_HOUR_EPOCH=$(date -d "$(date +"%Y-%m-%d %H:00:00")" +%s)
FALLBACK_USED=0
ROUTE_ROWS=""

for offset in $(seq 1 $((FALLBACK_MAX_HOURS + 1))); do
    WINDOW_END=$(date -d "@$((CURRENT_HOUR_EPOCH - offset*3600))" +"%Y-%m-%d %H:%M:%S")
    WINDOW_START=$(date -d "@$((CURRENT_HOUR_EPOCH - (offset+1)*3600))" +"%Y-%m-%d %H:%M:%S")
    ROUTE_ROWS=$(route_query "$WINDOW_START" "$WINDOW_END")
    if [ -n "$ROUTE_ROWS" ]; then
        FALLBACK_USED=$((offset - 1))
        break
    fi
done
WINDOW_LABEL="${WINDOW_START} -> ${WINDOW_END}"

section "SBC ROUTE-PREFIX TRAFFIC ANALYSIS — WINDOW: ${WINDOW_LABEL} (run at $(date '+%Y-%m-%d %H:%M:%S'))"

log ""
explain "Direction is derived from srcIp/dstIp (edge<->SBC), not the A/B prefix naming. Route Prefix/Name come from the R-URI's leading 3-char code, or from the rn= parameter for ported numbers, matched against the known per-site route sheet. TG/RL column: FROM_SBC rows show the ingress Trunk Group, TO_SBC rows show the egress Routing Label. Reports total INVITE counts per route -- no safe unique-call dedup key exists on this platform."
if [ "$FALLBACK_USED" -gt 0 ]; then
    log ""
    log "${YELLOW}NOTE: No data yet for the primary (most recent) hour — this report fell back ${FALLBACK_USED} hour(s) earlier to the most recent window that had data. This is normal shortly after an hour rolls over; try again in a few minutes for the freshest hour.${NC}"
fi
log ""

if [ -z "$ROUTE_ROWS" ]; then
    log "  (no data found in the last $((FALLBACK_MAX_HOURS + 1)) hours — check ingestion/import health)"
else
    declare -A GROUPMAX
    while IFS='|' read -r site direction prefix route_name tg_name total_invites; do
        [ -z "$site" ] && continue
        key="${site}|${direction}"
        cur=${GROUPMAX[$key]:-0}
        if [ "${total_invites:-0}" -gt "$cur" ]; then GROUPMAX[$key]=${total_invites:-0}; fi
    done <<< "$ROUTE_ROWS"

    declare -A GRP_TOTAL
    last_key=""

    while IFS='|' read -r site direction prefix route_name tg_name total_invites; do
        [ -z "$site" ] && continue
        key="${site}|${direction}"
        if [ "$key" != "$last_key" ]; then
            log ""
            log "${MAGENTA}${BOLD}--- ${site} — ${direction} ---${NC}"
            log "$(printf "%-8s %-24s %-24s %10s %s" "PREFIX" "ROUTE NAME" "TG / RL" "INVITES" "GRAPH")"
            last_key="$key"
        fi

        bar=$(make_bar "${total_invites:-0}" "${GROUPMAX[$key]:-0}" 30)
        PREFIX_F=$(printf "%-8s" "$prefix")
        NAME_F=$(printf "%-24s" "$route_name")
        TG_F=$(printf "%-24s" "$tg_name")
        TOT_F=$(printf "%10s" "${total_invites:-0}")

        log "${PREFIX_F} ${NAME_F} ${TG_F} ${TOT_F} ${bar}"

        GRP_TOTAL[$key]=$(( ${GRP_TOTAL[$key]:-0} + ${total_invites:-0} ))
    done <<< "$ROUTE_ROWS"

    log ""
    log "${CYAN}${BOLD}--- SUMMARY — TOTALS BY SITE / DIRECTION ---${NC}"
    log "$(printf "%-14s %-10s %10s" "SITE" "DIRECTION" "INVITES")"
    for key in "${!GRP_TOTAL[@]}"; do
        echo "$key|${GRP_TOTAL[$key]}"
    done | sort | while IFS='|' read -r key total; do
        site="${key%%|*}"; direction="${key##*|}"
        log "$(printf "%-14s %-10s %10s" "$site" "$direction" "$total")"
    done
fi

separator
log "${CYAN}${BOLD}=== SBC ROUTE ANALYSIS COMPLETE — $(date '+%Y-%m-%d %H:%M:%S') ===${NC}"
log ""

POST_LINES=$(wc -l < "$LOG_FILE")
echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"

exit 0
