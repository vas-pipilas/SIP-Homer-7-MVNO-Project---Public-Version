-- =============================================================================
-- SBC ROUTE-PREFIX TRAFFIC ANALYSIS (standalone, ad-hoc version)
-- Reports: Route Prefix / Route Name / TG-RL, by site and direction, in a
-- single combined result set (matched + unmatched rows together).
--
-- Direction is derived from srcIp/dstIp (edge<->SBC), NOT from the A/B
-- prefix naming convention:
--   FROM_SBC = srcIp is SBC, dstIp is edge  (carrier -> SBC -> core)
--   TO_SBC   = srcIp is edge, dstIp is SBC  (core -> SBC -> carrier)
--
-- Prefix extraction checks TWO locations:
--   1. ruri_user directly     e.g. "A02+306900000000"        (non-ported)
--   2. the rn= URI parameter  e.g. "...;npdi;rn=B21+3059..."  (ported numbers)
--
-- TG/RL column: FROM_SBC rows show the real ingress Trunk Group name.
-- TO_SBC rows show the egress Routing Label instead (the generic "core"
-- trunk group is identical for every outbound route, so the RL is the
-- meaningful egress identifier there).
--
-- Unmatched prefixes show up in the SAME result set with "(unmatched)" in
-- the Route Name/TG-RL columns, rather than a separate diagnostic query --
-- useful for spotting route-sheet drift or genuine no-route failures.
--
-- Scope: edge nodes only (the SBC<->core boundary).
--
-- Note: the route map below is a representative sample covering the
-- interesting patterns (onnet/offnet distinction, multiple carrier types,
-- ported-number handling) -- not an exhaustive real-world route sheet.
-- =============================================================================

WITH params AS (
    SELECT INTERVAL '24 hours' AS time_window   -- *** CHANGE WINDOW HERE ***
),

face_ips (site, ip) AS (
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
    CROSS JOIN params
    JOIN face_ips f ON (c.protocol_header->>'srcIp' = f.ip OR c.protocol_header->>'dstIp' = f.ip)
    JOIN sbc_ips  s ON (
        (c.protocol_header->>'srcIp' = s.ip AND c.protocol_header->>'dstIp' = f.ip) OR
        (c.protocol_header->>'dstIp' = s.ip AND c.protocol_header->>'srcIp' = f.ip)
    )
    WHERE c.data_header->>'method' = 'INVITE'
      AND f.site = s.site
      AND c.create_date >= NOW() - params.time_window
)

SELECT
    fc.site,
    fc.direction,
    COALESCE(fc.prefix, '(none)')          AS "Route Prefix",
    COALESCE(rm.route_name, '(unmatched)') AS "Route Name",
    COALESCE(rm.tg_name, '(unmatched)')    AS "TG / RL",
    COUNT(*)                               AS total_invites
FROM face_calls fc
LEFT JOIN route_map rm ON rm.site = fc.site AND rm.prefix = fc.prefix
GROUP BY fc.site, fc.direction, fc.prefix, rm.route_name, rm.tg_name
ORDER BY fc.site, fc.direction, "Route Prefix";
