# SOC SQL query library

Each query is provided in two dialects:

- `*_bq.sql` — **GoogleSQL** (BigQuery), reads from
  `genai_audit_xsiam_forwarder_audit.raw_<vendor>` tables, parses the
  `data` column with `JSON_VALUE()` / `JSON_EXTRACT_SCALAR()`.
- `*_athena.sql` — **Trino/Presto** (Athena), reads from
  `genai_audit_xsiam_forwarder_audit.<vendor>` Glue tables, parses the
  `actor` column with `json_extract_scalar()`.

## Query inventory

| File | Question it answers |
|---|---|
| `01_volume_by_vendor` | Event volume per feed per hour (volume trending, capacity planning) |
| `02_failed_auth` | Failed login / SSO events grouped by user (account-takeover indicator) |
| `03_api_key_lifecycle` | Every API key created / updated / deleted across both vendors (cross-vendor IAM audit) |
| `04_compliance_self_audit` | Every Compliance API request — who's reading the audit feeds themselves |
| `05_actor_geo_distribution` | Distinct source IPs per user (impossible-travel candidate signal) |
| `06_cross_vendor_user_activity` | Same user emails across Anthropic + OpenAI (joined identity view) |

## Looker Studio / QuickSight wiring

These queries can be:

1. **Pasted into a custom Looker Studio data source** (Resource → Manage
   added data sources → BigQuery → Custom Query). Refresh on a schedule.
2. **Saved as Athena Named Queries** then referenced as a QuickSight
   custom-SQL dataset.
3. **Materialized** into a separate table via:
   - BigQuery **scheduled queries** (BQ Console → Schedule)
   - Athena **CTAS** with date partitioning

For low-volume audit data the first option is fine — query latency is
seconds even on full table scans. For content feeds or Cowork OTel
volume, materialize first.

## Cost notes

| Platform | Per-query cost |
|---|---|
| BigQuery | $5 / TB scanned. The audit tables are tiny — most queries are pennies. Free tier covers the first 1 TB / month. |
| Athena | $5 / TB scanned. Partition projection on the Glue tables means most queries scan one partition — also pennies. |

If the same query runs on a Looker Studio dashboard refreshing every
15 minutes against multi-GB content feeds, costs add up. Materialize.
