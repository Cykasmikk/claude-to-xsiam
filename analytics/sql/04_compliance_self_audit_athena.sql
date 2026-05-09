-- Compliance API self-audit — Anthropic emits one compliance_api_accessed
-- event per call; useful for forwarder-health and abuse detection.

SELECT
  date_trunc('hour', from_iso8601_timestamp(created_at))     AS hour,
  count(*)                                                   AS request_count,
  count(DISTINCT json_extract_scalar(actor, '$.api_key_id')) AS distinct_keys,
  count(DISTINCT json_extract_scalar(actor, '$.ip_address')) AS distinct_ips,
  array_agg(DISTINCT json_extract_scalar(actor, '$.api_key_id'))
                                                             AS api_key_ids
FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
WHERE year >= year(current_date - interval '7' day)
  AND created_at >= to_iso8601(current_timestamp - interval '7' day)
  AND type = 'compliance_api_accessed'
GROUP BY 1
ORDER BY 1 DESC;
