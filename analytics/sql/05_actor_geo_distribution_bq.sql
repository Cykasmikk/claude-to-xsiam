-- Distinct source IPs per user across both vendors, last 7 days.
-- A row with distinct_ips > 3 in a 24h window is a candidate for
-- impossible-travel review (cross-reference with a geo-IP enrichment
-- in your downstream layer).

WITH anth AS (
  SELECT
    JSON_VALUE(data, '$.actor.email_address') AS user_email,
    JSON_VALUE(data, '$.actor.ip_address')    AS source_ip,
    publish_time                              AS event_time
  FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
    AND JSON_VALUE(data, '$.actor.email_address') IS NOT NULL
    AND JSON_VALUE(data, '$.actor.ip_address')    IS NOT NULL
),
oai AS (
  SELECT
    JSON_VALUE(data, '$.actor.session.user.email') AS user_email,
    JSON_VALUE(data, '$.actor.session.ip_address') AS source_ip,
    publish_time                                   AS event_time
  FROM `genai_audit_xsiam_forwarder_audit.raw_openai`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
    AND JSON_VALUE(data, '$.actor.session.user.email') IS NOT NULL
    AND JSON_VALUE(data, '$.actor.session.ip_address') IS NOT NULL
),
unioned AS (
  SELECT * FROM anth
  UNION ALL
  SELECT * FROM oai
)
SELECT
  user_email,
  COUNT(DISTINCT source_ip) AS distinct_ips,
  COUNT(*)                  AS event_count,
  MIN(event_time)           AS first_seen,
  MAX(event_time)           AS last_seen,
  ARRAY_AGG(DISTINCT source_ip ORDER BY source_ip) AS source_ips
FROM unioned
GROUP BY user_email
HAVING distinct_ips > 1
ORDER BY distinct_ips DESC, event_count DESC
LIMIT 100;
