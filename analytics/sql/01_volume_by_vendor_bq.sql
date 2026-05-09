-- Event volume per vendor per hour over the last 7 days.
-- Use as a Looker Studio time-series chart: x=hour, y=event_count, breakdown=vendor.

WITH all_vendors AS (
  SELECT 'anthropic' AS vendor, publish_time, data
    FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic`
   WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  UNION ALL
  SELECT 'anthropic_chats', publish_time, data
    FROM `genai_audit_xsiam_forwarder_audit.raw_anthropic_chats`
   WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  UNION ALL
  SELECT 'openai', publish_time, data
    FROM `genai_audit_xsiam_forwarder_audit.raw_openai`
   WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  UNION ALL
  SELECT 'openai_conversations', publish_time, data
    FROM `genai_audit_xsiam_forwarder_audit.raw_openai_conversations`
   WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
)
SELECT
  vendor,
  TIMESTAMP_TRUNC(publish_time, HOUR) AS hour,
  COUNT(*) AS event_count
FROM all_vendors
GROUP BY vendor, hour
ORDER BY hour DESC, vendor;
