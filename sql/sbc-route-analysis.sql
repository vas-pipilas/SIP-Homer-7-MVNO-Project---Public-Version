-- =============================================================================
-- Sanitized standalone SBC route-prefix analysis
--
-- All network ranges are RFC 5737 documentation addresses and all carriers,
-- route prefixes and route references are fictionalized.
-- =============================================================================

WITH params AS (
    SELECT INTERVAL '24 hours' AS time_window
),
edge_ips(site,ip) AS (
    VALUES
      ('Site A','192.0.2.21'),('Site A','192.0.2.22'),
      ('Site B','198.51.100.21'),('Site B','198.51.100.22')
),
sbc_ips(site,ip) AS (
    VALUES
      ('Site A','192.0.2.45'),('Site A','192.0.2.46'),
      ('Site B','198.51.100.45'),('Site B','198.51.100.46')
),
route_map(site,prefix,route_name,route_ref) AS (
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
),
edge_calls AS (
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
    CROSS JOIN params
    JOIN edge_ips e ON c.protocol_header->>'srcIp'=e.ip OR c.protocol_header->>'dstIp'=e.ip
    JOIN sbc_ips s ON s.site=e.site AND (
         (c.protocol_header->>'srcIp'=s.ip AND c.protocol_header->>'dstIp'=e.ip)
      OR (c.protocol_header->>'dstIp'=s.ip AND c.protocol_header->>'srcIp'=e.ip)
    )
    WHERE c.data_header->>'method'='INVITE'
      AND c.create_date >= NOW()-params.time_window
)
SELECT
  c.site,
  c.direction,
  COALESCE(c.prefix,'(none)') AS route_prefix,
  COALESCE(r.route_name,'(unmatched)') AS route_name,
  COALESCE(r.route_ref,'(unmatched)') AS trunk_or_label,
  COUNT(*) AS invite_events
FROM edge_calls c
LEFT JOIN route_map r ON r.site=c.site AND r.prefix=c.prefix
GROUP BY c.site,c.direction,c.prefix,r.route_name,r.route_ref
ORDER BY c.site,c.direction,route_prefix;
