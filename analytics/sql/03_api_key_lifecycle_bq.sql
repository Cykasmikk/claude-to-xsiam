-- Every API key lifecycle event across both vendors, last 30 days.
-- Cross-vendor IAM audit table — useful for SOC reviewers checking
-- "who created/rotated/deleted which keys when".

WITH anth AS (
  SELECT
    'anthropic'                                   AS vendor,
    publish_time                                  AS event_time,
    JSON_VALUE(data, '$.id')                      AS event_id,
    JSON_VALUE(data, '$.type')                    AS event_type,
    JSON_VALUE(data, '$.actor.type')              AS actor_type,
    JSON_VALUE(data, '$.actor.email_address')     AS actor_email,
    JSON_VALUE(data, '$.actor.user_id')           AS actor_user_id,
    JSON_VALUE(data, '$.actor.api_key_id')        AS actor_api_key_id,
    JSON_VALUE(data, '$.api_key_id')              AS subject_api_key_id,
    JSON_VALUE(data, '$.organization_id')         AS organization_id
  FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND JSON_VALUE(data, '$.type') IN (
      'api_key_created', 'api_key_updated',
      'admin_api_key_created', 'admin_api_key_updated', 'admin_api_key_deleted',
      'platform_api_key_created', 'platform_api_key_updated',
      'scoped_api_key_deleted', 'scoped_api_key_updated'
    )
),
oai AS (
  SELECT
    'openai'                                                 AS vendor,
    publish_time                                             AS event_time,
    JSON_VALUE(data, '$.id')                                 AS event_id,
    JSON_VALUE(data, '$.type')                               AS event_type,
    CASE WHEN JSON_VALUE(data, '$.actor.session') IS NOT NULL THEN 'session'
         WHEN JSON_VALUE(data, '$.actor.api_key') IS NOT NULL THEN 'api_key'
         END                                                 AS actor_type,
    COALESCE(
      JSON_VALUE(data, '$.actor.session.user.email'),
      JSON_VALUE(data, '$.actor.api_key.user.email')
    )                                                        AS actor_email,
    COALESCE(
      JSON_VALUE(data, '$.actor.session.user.id'),
      JSON_VALUE(data, '$.actor.api_key.user.id')
    )                                                        AS actor_user_id,
    JSON_VALUE(data, '$.actor.api_key.id')                   AS actor_api_key_id,
    JSON_VALUE(data, '$.api_key.created.id')                 AS subject_api_key_id,
    NULL                                                     AS organization_id
  FROM `genai_audit_xsiam_forwarder_audit.raw_openai`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND JSON_VALUE(data, '$.type') IN ('api_key.created', 'api_key.updated', 'api_key.deleted')
)
SELECT * FROM anth
UNION ALL
SELECT * FROM oai
ORDER BY event_time DESC;
