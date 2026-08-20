#!/bin/bash
# =============================================================================
# homer-sbc-routes.sh — sanitized portfolio edition
#
# Classifies SBC-facing SIP INVITEs by a fictional three-character routing
# prefix stamped into either the R-URI user or the rn= portability parameter.
# Direction is derived independently from source/destination IPs; prefixes are
# treated only as route labels, never as ground truth for direction.
#
# Uses RFC 5737 documentation address ranges only.
# =============================================================================

set -u

DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="sip_capture"
DB_USER="sip_monitor"
CRED_FILE="/etc/sip-homer-toolkit/db.env"
LOG_DIR="/var/log/sip-homer-toolkit"
LOG_FILE="${LOG_DIR}/sbc-routes.log"
LINES_FILE="${LOG_FILE}.lines"
FALLBACK_MAX_HOURS=6

[ -r "$CRED_FILE" ] && source "$CRED_FILE"
[ -n "${SIP_MONITOR_PGPASSWORD:-}" ] && export PGPASSWORD="$SIP_MONITOR_PGPASSWORD"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE" "$LINES_FILE" 2>/dev/null || true
PRE_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)

log() { printf '%s\n' "$1" >> "$LOG_FILE"; }
db_query() {
    timeout 60 psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        --pset pager=off -t -A -F'|' -c "$1" 2>/dev/null
}

route_query() {
    local start="$1" end="$2"
    db_query "
WITH edge_ips(site,ip) AS (
  VALUES
    ('Site A','192.0.2.21'),('Site A','192.0.2.22'),
    ('Site B','198.51.100.21'),('Site B','198.51.100.22')
), sbc_ips(site,ip) AS (
  VALUES
    ('Site A','192.0.2.45'),('Site A','192.0.2.46'),
    ('Site B','198.51.100.45'),('Site B','198.51.100.46')
), route_map(site,prefix,route_name,route_ref) AS (
  VALUES
    ('Site A','A01','Carrier Alpha Mobile','TG_A_ALPHA_MOB'),
    ('Site A','A02','Carrier Alpha Fixed','TG_A_ALPHA_FIX'),
    ('Site A','A11','Carrier Beta Mobile','TG_A_BETA_MOB'),
    ('Site A','A21','Carrier Gamma','TG_A_GAMMA'),
    ('Site A','B01','Carrier Alpha Mobile','RL_A_ALPHA_MOB'),
    ('Site A','B02','Carrier Alpha Fixed','RL_A_ALPHA_FIX'),
    ('Site A','B11','Carrier Beta Mobile','RL_A_BETA_MOB'),
    ('Site A','B21','Carrier Gamma','RL_A_GAMMA'),
    ('Site B','A01','Carrier Alpha Mobile','TG_B_ALPHA_MOB'),
    ('Site B','A02','Carrier Alpha Fixed','TG_B_ALPHA_FIX'),
    ('Site B','A11','Carrier Beta Mobile','TG_B_BETA_MOB'),
    ('Site B','A21','Carrier Gamma','TG_B_GAMMA'),
    ('Site B','B01','Carrier Alpha Mobile','RL_B_ALPHA_MOB'),
    ('Site B','B02','Carrier Alpha Fixed','RL_B_ALPHA_FIX'),
    ('Site B','B11','Carrier Beta Mobile','RL_B_BETA_MOB'),
    ('Site B','B21','Carrier Gamma','RL_B_GAMMA')
), calls AS (
  SELECT
    e.site,
    CASE
      WHEN c.protocol_header->>'srcIp'=s.ip AND c.protocol_header->>'dstIp'=e.ip THEN 'FROM_SBC'
      WHEN c.protocol_header->>'srcIp'=e.ip AND c.protocol_header->>'dstIp'=s.ip THEN 'TO_SBC'
    END AS direction,
    COALESCE(
      substring(c.data_header->>'ruri_user' FROM '^[A-Z][0-9]{2}'),
      substring(c.raw FROM 'rn=([A-Z][0-9]{2})')
    ) AS prefix
  FROM hep_proto_1_call c
  JOIN edge_ips e ON c.protocol_header->>'srcIp'=e.ip OR c.protocol_header->>'dstIp'=e.ip
  JOIN sbc_ips s ON s.site=e.site AND (
       (c.protocol_header->>'srcIp'=s.ip AND c.protocol_header->>'dstIp'=e.ip)
    OR (c.protocol_header->>'dstIp'=s.ip AND c.protocol_header->>'srcIp'=e.ip)
  )
  WHERE c.data_header->>'method'='INVITE'
    AND c.create_date >= '${start}' AND c.create_date < '${end}'
)
SELECT c.site,c.direction,COALESCE(c.prefix,'(none)'),
       COALESCE(r.route_name,'(unmatched)'),COALESCE(r.route_ref,'(unmatched)'),COUNT(*)
FROM calls c
LEFT JOIN route_map r ON r.site=c.site AND r.prefix=c.prefix
GROUP BY c.site,c.direction,c.prefix,r.route_name,r.route_ref
ORDER BY c.site,c.direction,c.prefix;"
}

CURRENT=$(date -d "$(date '+%Y-%m-%d %H:00:00')" +%s)
ROWS=""; FALLBACK=0
for offset in $(seq 1 $((FALLBACK_MAX_HOURS + 1))); do
    END=$(date -d "@$((CURRENT-offset*3600))" '+%Y-%m-%d %H:%M:%S')
    START=$(date -d "@$((CURRENT-(offset+1)*3600))" '+%Y-%m-%d %H:%M:%S')
    ROWS=$(route_query "$START" "$END")
    if [ -n "$ROWS" ]; then FALLBACK=$((offset-1)); break; fi
done

log "============================================================"
log "SBC ROUTE ANALYSIS — ${START:-NO DATA} -> ${END:-NO DATA}"
log "Direction comes from addressing; route labels come from R-URI/rn= prefix mapping."
[ "$FALLBACK" -gt 0 ] && log "[WARN] Reporting fallback window ${FALLBACK} hour(s) earlier due to ingestion lag."
log ""
printf '%-8s %-10s %-8s %-24s %-22s %10s\n' "SITE" "DIRECTION" "PREFIX" "ROUTE" "TG / RL" "INVITES" >> "$LOG_FILE"
printf '%-8s %-10s %-8s %-24s %-22s %10s\n' "--------" "----------" "--------" "------------------------" "----------------------" "----------" >> "$LOG_FILE"
while IFS='|' read -r site direction prefix route ref count; do
    [ -z "$site" ] && continue
    printf '%-8s %-10s %-8s %-24s %-22s %10s\n' "$site" "$direction" "$prefix" "$route" "$ref" "$count" >> "$LOG_FILE"
done <<< "$ROWS"
log ""
log "Unmatched prefixes remain visible so route-sheet drift is observable."
log "============================================================"

POST_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "$PRE_LINES")
echo $((POST_LINES-PRE_LINES)) > "$LINES_FILE"
tail -n "$((POST_LINES-PRE_LINES))" "$LOG_FILE"
