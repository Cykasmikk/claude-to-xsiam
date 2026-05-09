# Looker Studio dashboard setup

Looker Studio (formerly Data Studio) is **free** and not Terraformable
— dashboards live in Google Drive. Manual setup, but the queries that
power them are in [`../sql/`](../sql/).

## Prerequisites

- Apply the [analytics/terraform/gcp](../terraform/gcp/) stack. After
  apply you have a BigQuery dataset (e.g.
  `genai_audit_xsiam_forwarder_audit`) with one `raw_<vendor>` table
  per audit feed.
- Wait 5–10 minutes for the first messages to arrive in BigQuery
  via the Pub/Sub subscriptions, otherwise the data sources show
  empty schemas.

## Step 1 — create a custom data source per query

In Looker Studio:

1. **Resource → Manage added data sources → Add a data source**
2. Pick **BigQuery** → **Custom Query**
3. Select your project, paste the contents of e.g.
   [`../sql/01_volume_by_vendor_bq.sql`](../sql/01_volume_by_vendor_bq.sql)
4. **Add** → name the source `01 - Volume by vendor`

Repeat for each `*_bq.sql` query you want a chart over.

## Step 2 — wire dashboards

Suggested dashboard layout — three pages:

### Page 1: Operational health

| Visual | Source |
|---|---|
| Time-series line chart, dim=`hour`, breakdown=`vendor`, metric=`event_count` | `01 - Volume by vendor` |
| Big-number scorecard, metric=`request_count` (today) | `04 - Compliance self-audit` |
| Time-series, dim=`hour`, metric=`distinct_keys` | `04 - Compliance self-audit` |

This page is what you check first thing each morning to see whether
the forwarder is alive across all vendors.

### Page 2: Identity & access

| Visual | Source |
|---|---|
| Table sorted by `event_time desc`, columns=vendor/event_type/actor_email/subject_api_key_id | `03 - API key lifecycle` |
| Bar chart, dim=`user_email`, metric=`failure_count`, filter=`failure_count > 5` | `02 - Failed auth` |
| Table, dim=`cohort`/`user_email` | `06 - Cross-vendor user activity` |

For SOC handoff or quarterly access reviews.

### Page 3: Threat indicators

| Visual | Source |
|---|---|
| Bar chart, dim=`user_email`, metric=`distinct_ips`, filter=`distinct_ips > 1`, sorted desc | `05 - Actor geo distribution` |
| Geo map (after enriching `source_ips` upstream — Looker Studio has no built-in IP→geo) | `05 - Actor geo distribution` (post-enrichment) |
| Time-series of `failure_count` by `event_type` | `02 - Failed auth` |

## Step 3 — share with the SOC team

1. **Share** → set access to your SOC group (typically Viewer).
2. The dashboard pulls from BigQuery on every load, so viewers don't
   need direct BigQuery access — just dashboard access.
3. **Important:** the underlying BigQuery dataset still needs viewer
   access for Looker Studio to query on the viewer's behalf. Configure
   `bigquery.dataViewer` for the dashboard's audience on
   `genai_audit_xsiam_forwarder_audit`.

## Refresh policy

Looker Studio caches BigQuery results for 12 hours by default. For
near-real-time dashboards: **File → Report settings → Data freshness
→ 15 minutes** (warning: each refresh re-runs the query, paying
BigQuery scan cost. At audit volume this is pennies; at content-feed
volume it adds up. Materialize via a scheduled query first if needed.)

## Embedding & alerts

Looker Studio supports email-scheduled PDF / image delivery (great for
weekly SOC summaries) and embedding via signed URLs. Threshold-based
alerting requires a separate tool — we recommend Cloud Monitoring
alert policies on a BigQuery scheduled query that materializes the
"things to alert on" rows; see the alarms section of the parent
stack's [`docs/operations.md`](../../docs/operations.md#alarms).
