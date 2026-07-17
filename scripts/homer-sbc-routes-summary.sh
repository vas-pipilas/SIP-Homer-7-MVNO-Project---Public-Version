#!/bin/bash
# =============================================================================
# homer-sbc-routes-summary.sh
# Parses homer-sbc-routes.log (+ rotated archives) over a date/time range and
# produces table-based summarizations — NOT graphs, since route/provider data
# is categorical rather than a continuous trend.
#
# Pure text parsing of already-generated hourly reports — does NOT re-run
# any DB query. No database credentials needed.
#
# Summaries produced:
#   1. PER HOUR                — trend over time, by site/direction
#   2. PER PROVIDER (FROM_SBC) — Route Name, sorted by volume
#      PER PROVIDER (TO_SBC)   — Route Name, sorted by volume
#   3. PER TG / RL (FROM_SBC)  — TG Name, sorted by volume
#      PER TG / RL (TO_SBC)    — Routing Label, sorted by volume
#   4. PER SITE                — by site, FROM_SBC/TO_SBC/TOTAL
#
# NOTE: Per Provider / Per TG-RL are split by direction rather than pivoted.
# Inbound (FROM_SBC) routes distinguish PAL/MET for several carriers (a real
# onnet/offnet distinction, not collapsed); outbound (TO_SBC) routes for
# those same carriers have no PAL/MET split at all. A combined pivot table
# would show a real-but-meaningless zero on one side for every such row —
# splitting by direction avoids that entirely.
#
# Usage:
#   homer-sbc-routes-summary.sh                     -> today, 00:00 to now
#   homer-sbc-routes-summary.sh <date>               -> that whole day
#   homer-sbc-routes-summary.sh <start> <end>        -> custom range
#     (any date -d parseable string, e.g. "2026-07-07 08:00")
# =============================================================================

LOG_DIR="/var/log/homer"
OUT_LOG="${LOG_DIR}/homer-sbc-routes-summary.log"
LINES_FILE="${OUT_LOG}.lines"
LIVE_LOG="${LOG_DIR}/homer-sbc-routes.log"

# --- Colors ------------------------------------------------------------------
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$LOG_DIR"
touch "$OUT_LOG" 2>/dev/null; chmod 666 "$OUT_LOG" 2>/dev/null
touch "$LINES_FILE" 2>/dev/null; chmod 666 "$LINES_FILE" 2>/dev/null

PRE_LINES=$(wc -l < "$OUT_LOG" 2>/dev/null || echo 0)

log() { printf '%b\n' "$1" >> "$OUT_LOG"; }

# --- Resolve START_TS / END_TS from arguments ---------------------------------
if [ -z "$1" ]; then
    START_TS="$(date +%Y-%m-%d) 00:00:00"
    END_TS="$(date +"%Y-%m-%d %H:%M:%S")"
elif [ -z "$2" ]; then
    START_TS="$(date -d "$1" +%Y-%m-%d) 00:00:00"
    END_TS="$(date -d "$(date -d "$1" +%Y-%m-%d) +1 day" +%Y-%m-%d) 00:00:00"
else
    START_TS=$(date -d "$1" +"%Y-%m-%d %H:%M:%S")
    END_TS=$(date -d "$2" +"%Y-%m-%d %H:%M:%S")
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

START_DAY_EPOCH=$(date -d "$(date -d "$START_TS" +%Y-%m-%d)" +%s)
END_DAY_EPOCH=$(date -d "$(date -d "$END_TS" +%Y-%m-%d)" +%s)
TODAY_COMPACT=$(date +%Y%m%d)

: > "$TMPDIR/combined.log"
d=$START_DAY_EPOCH
while [ "$d" -le "$END_DAY_EPOCH" ]; do
    day_compact=$(date -d "@$d" +%Y%m%d)
    gz="${LOG_DIR}/homer-sbc-routes_${day_compact}.log.gz"
    plain="${LOG_DIR}/homer-sbc-routes_${day_compact}.log"
    if [ -f "$gz" ]; then
        zcat "$gz" >> "$TMPDIR/combined.log"
    elif [ -f "$plain" ]; then
        cat "$plain" >> "$TMPDIR/combined.log"
    elif [ "$day_compact" = "$TODAY_COMPACT" ] && [ -f "$LIVE_LOG" ]; then
        cat "$LIVE_LOG" >> "$TMPDIR/combined.log"
    fi
    d=$((d + 86400))
done

TODAY_EPOCH=$(date -d "$(date +%Y-%m-%d)" +%s)
if [ "$TODAY_EPOCH" -gt "$END_DAY_EPOCH" ] && [ -f "$LIVE_LOG" ]; then
    cat "$LIVE_LOG" >> "$TMPDIR/combined.log"
fi

if [ ! -s "$TMPDIR/combined.log" ]; then
    log "No log source found for range ${START_TS} -> ${END_TS}"
    POST_LINES=$(wc -l < "$OUT_LOG"); echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"
    exit 1
fi

# =============================================================================
# PARSE — strip ANSI colors, extract per-route detail rows scoped to the
# requested window, using fixed-column positions matching homer-sbc-routes.sh's
# printf widths: PREFIX(8) NAME(28) TG/RL(30) INVITES(10), single-space separated.
# =============================================================================
sed -r 's/\x1b\[[0-9;]*m//g' "$TMPDIR/combined.log" | awk \
    -v START_TS="$START_TS" -v END_TS="$END_TS" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

/=== SBC ROUTE-PREFIX TRAFFIC ANALYSIS — WINDOW:/ {
    match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:00:00/)
    cur_hour = substr($0, RSTART, RLENGTH)
    active = (cur_hour >= START_TS && cur_hour < END_TS) ? 1 : 0
    in_table = 0
    next
}
!active { next }

/^---/ {
    if ($0 ~ /SUMMARY/)    { in_table = 0; next }
    if ($0 ~ /DIAGNOSTIC/) { in_table = 0; next }
    if ($0 ~ /Site A/ || $0 ~ /Site B/) {
        cur_site = ($0 ~ /Site A/) ? "Site A" : "Site B"
        cur_dir  = ($0 ~ /FROM_SBC/) ? "FROM_SBC" : "TO_SBC"
        in_table = 1
        skip_next = 1
        next
    }
    next
}
/^$/ { next }
in_table && skip_next { skip_next = 0; next }   # skip the column-header line
in_table {
    prefix     = trim(substr($0, 1, 8))
    route_name = trim(substr($0, 10, 28))
    tg_rl      = trim(substr($0, 39, 30))
    invites    = trim(substr($0, 70, 10)) + 0
    if (prefix != "" && prefix != "PREFIX")
        print cur_hour "|" cur_site "|" cur_dir "|" prefix "|" route_name "|" tg_rl "|" invites
}
' > "$TMPDIR/parsed.dat"

if [ ! -s "$TMPDIR/parsed.dat" ]; then
    log "No route data parsed for range ${START_TS} -> ${END_TS} — check the source logs cover this window."
    POST_LINES=$(wc -l < "$OUT_LOG"); echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"
    exit 1
fi

{
echo "============================================================"
echo "=== SBC ROUTE SUMMARY — ${START_TS} -> ${END_TS} (generated $(date '+%Y-%m-%d %H:%M:%S')) ==="
echo "============================================================"
} >> "$OUT_LOG"

# =============================================================================
# 1. PER HOUR — trend over time, by site/direction
# =============================================================================
log ""
log "${CYAN}${BOLD}--- PER HOUR ---${NC}"
log "$(printf "%-16s %14s %14s %14s %14s %10s" "TIME" "ATH_FROM_SBC" "ATH_TO_SBC" "THE_FROM_SBC" "THE_TO_SBC" "TOTAL")"

awk -F'|' '{
    hour = $1
    key = hour SUBSEP $2 SUBSEP $3
    sum[key] += $7
    total[hour] += $7
    if (!(hour in seen)) { seen[hour]=1; hours[++n]=hour }
}
END {
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (hours[i] > hours[j]) { t=hours[i]; hours[i]=hours[j]; hours[j]=t }
    for (i=1;i<=n;i++) {
        h = hours[i]
        af = sum[h SUBSEP "Site A" SUBSEP "FROM_SBC"] + 0
        at = sum[h SUBSEP "Site A" SUBSEP "TO_SBC"] + 0
        tf = sum[h SUBSEP "Site B" SUBSEP "FROM_SBC"] + 0
        tt = sum[h SUBSEP "Site B" SUBSEP "TO_SBC"] + 0
        printf "%-16s %14d %14d %14d %14d %10d\n", h, af, at, tf, tt, total[h]
    }
}' "$TMPDIR/parsed.dat" >> "$OUT_LOG"

# =============================================================================
# 2. PER PROVIDER — split by direction (see header note on why not pivoted)
# =============================================================================
for DIR in FROM_SBC TO_SBC; do
    log ""
    log "${CYAN}${BOLD}--- PER PROVIDER (${DIR}) ---${NC}"
    log "$(printf "%-32s %10s" "ROUTE NAME" "INVITES")"
    awk -F'|' -v d="$DIR" '$3==d { sum[$5] += $7 }
    END { for (name in sum) printf "%s|%d\n", name, sum[name] }' "$TMPDIR/parsed.dat" \
    | sort -t'|' -k2,2 -nr \
    | while IFS='|' read -r name invites; do
        log "$(printf "%-32s %10d" "$name" "$invites")"
    done
done

# =============================================================================
# 3. PER TG / RL — split by direction (see header note)
# =============================================================================
for DIR in FROM_SBC TO_SBC; do
    log ""
    log "${CYAN}${BOLD}--- PER TG / RL (${DIR}) ---${NC}"
    log "$(printf "%-34s %10s" "TG / RL" "INVITES")"
    awk -F'|' -v d="$DIR" '$3==d { sum[$6] += $7 }
    END { for (tg in sum) printf "%s|%d\n", tg, sum[tg] }' "$TMPDIR/parsed.dat" \
    | sort -t'|' -k2,2 -nr \
    | while IFS='|' read -r tg invites; do
        log "$(printf "%-34s %10d" "$tg" "$invites")"
    done
done

# =============================================================================
# 4. PER SITE — FROM_SBC/TO_SBC/TOTAL (both directions have real data here,
# so a pivoted table makes sense)
# =============================================================================
log ""
log "${MAGENTA}${BOLD}--- PER SITE ---${NC}"
log "$(printf "%-16s %14s %14s %10s" "SITE" "FROM_SBC" "TO_SBC" "TOTAL")"

awk -F'|' '{
    site = $2
    key = site SUBSEP $3
    sum[key] += $7
    total[site] += $7
    if (!(site in seen)) { seen[site]=1; sites[++n]=site }
}
END {
    for (i=1;i<=n;i++) {
        s = sites[i]
        f = sum[s SUBSEP "FROM_SBC"] + 0
        t = sum[s SUBSEP "TO_SBC"] + 0
        printf "%-16s %14d %14d %10d\n", s, f, t, total[s]
    }
}' "$TMPDIR/parsed.dat" >> "$OUT_LOG"

log ""
log "============================================================"

POST_LINES=$(wc -l < "$OUT_LOG")
echo $((POST_LINES - PRE_LINES)) > "$LINES_FILE"

exit 0
