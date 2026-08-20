#!/bin/bash
# =============================================================================
# homer-sbc-routes-summary.sh — sanitized portfolio edition
#
# Builds historical summaries by parsing persisted SBC route-analysis logs.
# It intentionally does not re-query the SIP database for every historical
# request. This makes historical review cheap and keeps the original observed
# output auditable.
# =============================================================================

set -u

LOG_DIR="/var/log/sip-homer-toolkit"
SOURCE_LOG="${LOG_DIR}/sbc-routes.log"
OUT_LOG="${LOG_DIR}/sbc-routes-summary.log"
LINES_FILE="${OUT_LOG}.lines"

mkdir -p "$LOG_DIR"
touch "$OUT_LOG" "$LINES_FILE" 2>/dev/null || true
PRE=$(wc -l < "$OUT_LOG" 2>/dev/null || echo 0)

START_DATE="${1:-$(date '+%Y-%m-%d')}"
END_DATE="${2:-$START_DATE}"

collect_logs() {
    local f
    for f in "$SOURCE_LOG" "${LOG_DIR}"/sbc-routes_*.log "${LOG_DIR}"/sbc-routes_*.log.gz; do
        [ -e "$f" ] || continue
        case "$f" in
            *.gz) gzip -cd -- "$f" ;;
            *) cat -- "$f" ;;
        esac
    done
}

{
    echo "============================================================"
    echo "SBC ROUTE HISTORICAL SUMMARY"
    echo "Requested range: ${START_DATE} -> ${END_DATE}"
    echo "Source: persisted sanitized route-analysis logs"
    echo "============================================================"
    echo

    # Current public route logs contain a heading with a reporting window,
    # followed by fixed-column route rows. This parser demonstrates the design
    # rather than depending on private provider/site names.
    collect_logs | awk -v start="$START_DATE" -v end="$END_DATE" '
      /^SBC ROUTE ANALYSIS — / {
        split($0,a," — ");
        d=substr(a[2],1,10);
        active=(d>=start && d<=end);
        if(active){ windows[d]++ }
        next
      }
      active && ($1=="Site") && ($2=="A" || $2=="B") {
        site=$1" "$2; direction=$3; prefix=$4;
        count=$NF+0;
        key=site SUBSEP direction;
        site_dir[key]+=count;
        prefix_tot[prefix]+=count;
        total+=count;
      }
      END {
        print "--- TOTAL EVENTS BY SITE / DIRECTION ---";
        for(k in site_dir){ split(k,p,SUBSEP); printf "%-8s %-10s %10d\n",p[1],p[2],site_dir[k] }
        print "";
        print "--- TOTAL EVENTS BY ROUTE PREFIX ---";
        for(p in prefix_tot){ printf "%-8s %10d\n",p,prefix_tot[p] }
        print "";
        printf "TOTAL MATCHED ROUTE EVENTS: %d\n",total;
      }'

    echo
    echo "============================================================"
} >> "$OUT_LOG"

POST=$(wc -l < "$OUT_LOG" 2>/dev/null || echo "$PRE")
echo $((POST-PRE)) > "$LINES_FILE"
tail -n "$((POST-PRE))" "$OUT_LOG"
