-- Failed login / SSO events grouped by user, last 24h.
-- Surfaces account-takeover candidates. Threshold is policy-dependent;
-- 5+ failures from one user inside a 1-hour window is a typical alert.

WITH anth AS (
  SELECT
    JSON_VALUE(data, '$.actor.email_address') AS user_email,
    JSON_VALUE(data, '$.actor.ip_address')    AS source_ip,
    JSON_VALUE(data, '$.type')                AS event_type,
    publish_time
  FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
    AND JSON_VALUE(data, '$.type') IN (
      'sso_login_failed', 'magic_link_login_failed', 'social_login_failed'
    )
),
oai AS (
  SELECT
    JSON_VALUE(data, '$.actor.session.user.email')      AS user_email,
    JSON_VALUE(data, '$.actor.session.ip_address')      AS source_ip,
    JSON_VALUE(data, '$.type')                          AS event_type,
    publish_time
  FROM `genai_audit_xsiam_forwarder_audit.raw_openai`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
    AND JSON_VALUE(data, '$.type') IN ('login.failed', 'logout.failed')
)
SELECT 'anthropic' AS vendor, user_email, source_ip, event_type,
       COUNT(*)                                      AS failure_count,
       COUNT(DISTINCT source_ip)                     AS distinct_ips,
       MIN(publish_time)                             AS first_seen,
       MAX(publish_time)                             AS last_seen
FROM anth
GROUP BY user_email, source_ip, event_type
UNION ALL
SELECT 'openai', user_email, source_ip, event_type,
       COUNT(*), COUNT(DISTINCT source_ip),
       MIN(publish_time), MAX(publish_time)
FROM oai
GROUP BY user_email, source_ip, event_type
ORDER BY failure_count DESC
LIMIT 200;
