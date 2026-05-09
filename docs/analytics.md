# Analytics dashboards (optional)

The forwarder's primary destination is XSIAM. For ad-hoc SOC
exploration, executive dashboards, and self-serve querying without
XSIAM seats, deploy the optional analytics layer in
[`analytics/`](../analytics/).

| Cloud | Warehouse | Dashboards | Cost |
|---|---|---|---|
| **GCP** | BigQuery (loaded via Pub/Sub → BQ subscriptions) | [Looker Studio](../analytics/dashboards/looker_studio.md) — free | ~$0/mo at audit volume |
| **AWS** | Athena over the existing S3 audit bucket (Glue Data Catalog) | [QuickSight](../analytics/dashboards/quicksight.md) — $18-24/user/mo, OR any tool that speaks Athena (Tableau, Metabase, Grafana) | ~$0.50/mo Athena + QS licensing if used |

The analytics layer **coexists** with XSIAM ingestion — both consume
the same upstream feeds independently. No data duplication beyond what
the warehouse itself stores.

## Quickstart

1. Apply the parent forwarder stack first
   (`terraform/{aws,gcp}/apply`).
2. Apply the analytics stack
   (`analytics/terraform/{aws,gcp}/apply`) — it reads the parent
   stack's outputs as inputs.
3. Wait 5-10 min for events to flow.
4. Wire up Looker Studio (GCP) or QuickSight (AWS) per the docs in
   [`analytics/dashboards/`](../analytics/dashboards/).

The SQL query library in [`analytics/sql/`](../analytics/sql/)
provides 6 production-grade SOC queries in both BigQuery and Athena
dialects:

1. Volume by vendor + hour
2. Failed-auth events grouped by user
3. API key lifecycle (cross-vendor)
4. Compliance API self-audit (forwarder-health and abuse signal)
5. Actor source-IP distribution (impossible-travel candidate)
6. Cross-vendor user activity (joined identity by email)

## Privacy

The analytics tier sees the same audit data as XSIAM. If your parent
stack has content feeds enabled (`anthropic_chats`,
`openai_conversations`, Cowork OTel) the analytics warehouse holds
prompt/response transcripts. Apply the same data-classification
controls — see [`docs/security.md`](security.md#data-classification).
