-- Distinct source IPs per user across both vendors, last 7 days.

WITH anth AS (
  SELECT
    json_extract_scalar(actor, '$.email_address') AS user_email,
    json_extract_scalar(actor, '$.ip_address')    AS source_ip,
    from_iso8601_timestamp(created_at)            AS event_time
  FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
  WHERE year >= year(current_date - interval '7' day)
    AND created_at >= to_iso8601(current_timestamp - interval '7' day)
    AND json_extract_scalar(actor, '$.email_address') IS NOT NULL
    AND json_extract_scalar(actor, '$.ip_address')    IS NOT NULL
),
oai AS (
  SELECT
    json_extract_scalar(actor, '$.session.user.email') AS user_email,
    json_extract_scalar(actor, '$.session.ip_address') AS source_ip,
    from_iso8601_timestamp(created_at)                 AS event_time
  FROM "genai_audit_xsiam_forwarder_audit"."openai"
  WHERE year >= year(current_date - interval '7' day)
    AND created_at >= to_iso8601(current_timestamp - interval '7' day)
    AND json_extract_scalar(actor, '$.session.user.email') IS NOT NULL
    AND json_extract_scalar(actor, '$.session.ip_address') IS NOT NULL
),
unioned AS (
  SELECT * FROM anth
  UNION ALL
  SELECT * FROM oai
)
SELECT
  user_email,
  count(DISTINCT source_ip) AS distinct_ips,
  count(*)                  AS event_count,
  min(event_time)           AS first_seen,
  max(event_time)           AS last_seen,
  array_agg(DISTINCT source_ip) AS source_ips
FROM unioned
GROUP BY user_email
HAVING count(DISTINCT source_ip) > 1
ORDER BY distinct_ips DESC, event_count DESC
LIMIT 100;
