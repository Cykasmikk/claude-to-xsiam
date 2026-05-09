-- Every API key lifecycle event across both vendors, last 30 days.

WITH anth AS (
  SELECT
    'anthropic'                                          AS vendor,
    from_iso8601_timestamp(created_at)                   AS event_time,
    id                                                   AS event_id,
    type                                                 AS event_type,
    json_extract_scalar(actor, '$.type')                 AS actor_type,
    json_extract_scalar(actor, '$.email_address')        AS actor_email,
    json_extract_scalar(actor, '$.user_id')              AS actor_user_id,
    json_extract_scalar(actor, '$.api_key_id')           AS actor_api_key_id,
    json_extract_scalar(raw_event, '$.api_key_id')       AS subject_api_key_id,
    organization_id
  FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
  WHERE year >= year(current_date - interval '30' day)
    AND created_at >= to_iso8601(current_timestamp - interval '30' day)
    AND type IN (
      'api_key_created', 'api_key_updated',
      'admin_api_key_created', 'admin_api_key_updated', 'admin_api_key_deleted',
      'platform_api_key_created', 'platform_api_key_updated',
      'scoped_api_key_deleted', 'scoped_api_key_updated'
    )
),
oai AS (
  SELECT
    'openai'                                                              AS vendor,
    from_iso8601_timestamp(created_at)                                    AS event_time,
    id                                                                    AS event_id,
    type                                                                  AS event_type,
    CASE WHEN json_extract(actor, '$.session') IS NOT NULL THEN 'session'
         WHEN json_extract(actor, '$.api_key') IS NOT NULL THEN 'api_key'
    END                                                                   AS actor_type,
    coalesce(
      json_extract_scalar(actor, '$.session.user.email'),
      json_extract_scalar(actor, '$.api_key.user.email')
    )                                                                     AS actor_email,
    coalesce(
      json_extract_scalar(actor, '$.session.user.id'),
      json_extract_scalar(actor, '$.api_key.user.id')
    )                                                                     AS actor_user_id,
    json_extract_scalar(actor, '$.api_key.id')                            AS actor_api_key_id,
    json_extract_scalar(raw_event, '$."api_key.created".id')              AS subject_api_key_id,
    CAST(NULL AS varchar)                                                 AS organization_id
  FROM "genai_audit_xsiam_forwarder_audit"."openai"
  WHERE year >= year(current_date - interval '30' day)
    AND created_at >= to_iso8601(current_timestamp - interval '30' day)
    AND type IN ('api_key.created', 'api_key.updated', 'api_key.deleted')
)
SELECT * FROM anth
UNION ALL
SELECT * FROM oai
ORDER BY event_time DESC;
