-- Same user emails seen across both vendors in the last 7 days.

WITH anth_users AS (
  SELECT DISTINCT
    lower(json_extract_scalar(actor, '$.email_address')) AS user_email
  FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
  WHERE year >= year(current_date - interval '7' day)
    AND created_at >= to_iso8601(current_timestamp - interval '7' day)
    AND json_extract_scalar(actor, '$.email_address') IS NOT NULL
),
oai_users AS (
  SELECT DISTINCT
    lower(coalesce(
      json_extract_scalar(actor, '$.session.user.email'),
      json_extract_scalar(actor, '$.api_key.user.email')
    )) AS user_email
  FROM "genai_audit_xsiam_forwarder_audit"."openai"
  WHERE year >= year(current_date - interval '7' day)
    AND created_at >= to_iso8601(current_timestamp - interval '7' day)
),
joined AS (
  SELECT
    coalesce(a.user_email, o.user_email) AS user_email,
    a.user_email IS NOT NULL             AS has_anthropic,
    o.user_email IS NOT NULL             AS has_openai
  FROM anth_users a
  FULL OUTER JOIN oai_users o
    ON a.user_email = o.user_email
)
SELECT
  CASE
    WHEN has_anthropic AND has_openai THEN 'both'
    WHEN has_anthropic                 THEN 'anthropic_only'
    WHEN has_openai                    THEN 'openai_only'
  END AS cohort,
  user_email
FROM joined
WHERE user_email IS NOT NULL
ORDER BY cohort, user_email;
