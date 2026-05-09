-- Failed login / SSO events grouped by user, last 24h.

WITH anth AS (
  SELECT
    json_extract_scalar(actor, '$.email_address') AS user_email,
    json_extract_scalar(actor, '$.ip_address')    AS source_ip,
    type                                          AS event_type,
    from_iso8601_timestamp(created_at)            AS event_ts
  FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
  WHERE year >= year(current_date - interval '1' day)
    AND created_at >= to_iso8601(current_timestamp - interval '24' hour)
    AND type IN ('sso_login_failed', 'magic_link_login_failed', 'social_login_failed')
),
oai AS (
  SELECT
    json_extract_scalar(actor, '$.session.user.email')   AS user_email,
    json_extract_scalar(actor, '$.session.ip_address')   AS source_ip,
    type                                                 AS event_type,
    from_iso8601_timestamp(created_at)                   AS event_ts
  FROM "genai_audit_xsiam_forwarder_audit"."openai"
  WHERE year >= year(current_date - interval '1' day)
    AND created_at >= to_iso8601(current_timestamp - interval '24' hour)
    AND type IN ('login.failed', 'logout.failed')
)
SELECT 'anthropic' AS vendor, user_email, source_ip, event_type,
       count(*)                AS failure_count,
       count(DISTINCT source_ip) AS distinct_ips,
       min(event_ts)           AS first_seen,
       max(event_ts)           AS last_seen
FROM anth
GROUP BY user_email, source_ip, event_type
UNION ALL
SELECT 'openai', user_email, source_ip, event_type,
       count(*), count(DISTINCT source_ip),
       min(event_ts), max(event_ts)
FROM oai
GROUP BY user_email, source_ip, event_type
ORDER BY failure_count DESC
LIMIT 200;
