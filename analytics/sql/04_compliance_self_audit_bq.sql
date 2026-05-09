-- Compliance API self-audit — every Compliance API request the forwarder
-- (or anyone else with the key) made. Sudden volume spike = forwarder
-- bug or attacker-initiated audit-log enumeration; sudden silence =
-- forwarder down.
--
-- Anthropic emits one `compliance_api_accessed` event per call. OpenAI
-- documents that "all authenticated requests to this API are logged"
-- but doesn't surface them as a distinct event-type — fall back to
-- counting all events from the api_actor.

SELECT
  TIMESTAMP_TRUNC(publish_time, HOUR)        AS hour,
  COUNT(*)                                   AS request_count,
  COUNT(DISTINCT JSON_VALUE(data, '$.actor.api_key_id')) AS distinct_keys,
  COUNT(DISTINCT JSON_VALUE(data, '$.actor.ip_address')) AS distinct_ips,
  ARRAY_AGG(DISTINCT JSON_VALUE(data, '$.actor.api_key_id') IGNORE NULLS) AS api_key_ids
FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND JSON_VALUE(data, '$.type') = 'compliance_api_accessed'
GROUP BY hour
ORDER BY hour DESC;
