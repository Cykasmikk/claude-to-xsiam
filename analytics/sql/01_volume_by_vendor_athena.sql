-- Event volume per vendor per hour over the last 7 days.
-- Athena/Trino dialect. Use as a QuickSight time-series visual.
-- Glue partition projection scans only the relevant date partitions.

WITH all_vendors AS (
  SELECT 'anthropic' AS vendor,
         from_iso8601_timestamp(created_at) AS event_ts
    FROM "genai_audit_xsiam_forwarder_audit"."anthropic"
   WHERE year >= year(current_date - interval '7' day)
     AND created_at >= to_iso8601(current_timestamp - interval '7' day)
  UNION ALL
  SELECT 'anthropic_chats',
         from_iso8601_timestamp(created_at)
    FROM "genai_audit_xsiam_forwarder_audit"."anthropic_chats"
   WHERE year >= year(current_date - interval '7' day)
     AND created_at >= to_iso8601(current_timestamp - interval '7' day)
  UNION ALL
  SELECT 'openai',
         from_iso8601_timestamp(created_at)
    FROM "genai_audit_xsiam_forwarder_audit"."openai"
   WHERE year >= year(current_date - interval '7' day)
     AND created_at >= to_iso8601(current_timestamp - interval '7' day)
  UNION ALL
  SELECT 'openai_conversations',
         from_iso8601_timestamp(created_at)
    FROM "genai_audit_xsiam_forwarder_audit"."openai_conversations"
   WHERE year >= year(current_date - interval '7' day)
     AND created_at >= to_iso8601(current_timestamp - interval '7' day)
)
SELECT
  vendor,
  date_trunc('hour', event_ts) AS hour,
  count(*) AS event_count
FROM all_vendors
GROUP BY vendor, date_trunc('hour', event_ts)
ORDER BY hour DESC, vendor;
