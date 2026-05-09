-- Same user emails seen across both vendors in the last 7 days.
-- Useful for joined-identity analytics: "show me everything user X did
-- in the GenAI tooling" — most enterprises grant the same person both
-- Claude and ChatGPT seats, so the email is the natural join key.

WITH anth_users AS (
  SELECT DISTINCT
    LOWER(JSON_VALUE(data, '$.actor.email_address')) AS user_email
  FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
    AND JSON_VALUE(data, '$.actor.email_address') IS NOT NULL
),
oai_users AS (
  SELECT DISTINCT
    LOWER(COALESCE(
      JSON_VALUE(data, '$.actor.session.user.email'),
      JSON_VALUE(data, '$.actor.api_key.user.email')
    )) AS user_email
  FROM `genai_audit_xsiam_forwarder_audit.raw_openai`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
),
joined AS (
  SELECT
    COALESCE(a.user_email, o.user_email) AS user_email,
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
