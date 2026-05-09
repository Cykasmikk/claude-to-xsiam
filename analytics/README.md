# Analytics layer

Optional Terraform stacks that put a SQL warehouse + dashboarding tier
on top of the existing forwarder. Two parallel implementations:

- **GCP:** Pub/Sub → BigQuery subscription → BigQuery dataset → Looker
  Studio dashboards
- **AWS:** S3 (already there from the parent stack) → Glue Data Catalog
  → Athena workgroup → QuickSight dashboards

Designed to coexist with the XSIAM ingestion path — both consume the
same upstream feeds independently.

## Why a second warehouse?

XSIAM is the SOC's primary system of record. The analytics layer here
is for ad-hoc exploration, executive dashboards, and self-serve queries
where the SOC team doesn't want to (or can't) hand out XSIAM seats.
Same data, different consumption pattern.

If you already get everything you need out of XSIAM XQL, you don't need
this layer.

## Costs at a glance

| Component | Cost |
|---|---|
| **GCP — BigQuery** | $5/TB scanned. First 1TB/month free. Audit volume is tiny — most queries are pennies. |
| **GCP — Pub/Sub → BQ subscription** | Free (consumed Pub/Sub already exists). |
| **GCP — Looker Studio** | **Free.** Renamed from Data Studio in 2024. |
| **AWS — Athena** | $5/TB scanned. Glue partition projection means most queries scan one partition (cents). |
| **AWS — Glue Data Catalog** | Free up to 1M objects. We have ≪1M. |
| **AWS — QuickSight** | **$18-24/user/month.** Real cost gate. |

Net: GCP analytics is essentially free; AWS adds **$18-24/user/month**
for QuickSight if you want hosted dashboards. If you don't have
QuickSight licensing, point Tableau / Looker Cloud / Metabase at the
Athena workgroup instead — same SQL queries work.

## Layout

```
analytics/
├── README.md                              this file
├── terraform/
│   ├── aws/                               Glue + Athena over the parent stack's S3 bucket
│   └── gcp/                               BigQuery + Pub/Sub-to-BQ subscriptions
├── sql/                                   6 SOC queries × 2 dialects each
│   ├── README.md
│   ├── 01_volume_by_vendor_{bq,athena}.sql
│   ├── 02_failed_auth_{bq,athena}.sql
│   ├── 03_api_key_lifecycle_{bq,athena}.sql
│   ├── 04_compliance_self_audit_{bq,athena}.sql
│   ├── 05_actor_geo_distribution_{bq,athena}.sql
│   └── 06_cross_vendor_user_activity_{bq,athena}.sql
└── dashboards/
    ├── looker_studio.md                   manual setup walkthrough (LS isn't TF-able)
    └── quicksight.md                      manual setup walkthrough (QS dashboards are TF-able but their JSON breaks per minor release; manual is more durable)
```

## Deploy — GCP

The analytics stack reads two outputs from the parent forwarder stack:
the project id and the per-vendor `xsiam_audit_topics` map.

```bash
cd analytics/terraform/gcp
terraform init
terraform apply \
  -var "project_id=<your-gcp-project>" \
  -var 'audit_topics={
        anthropic="projects/<gcp-project>/topics/genai-audit-xsiam-forwarder-anthropic-audit",
        openai="projects/<gcp-project>/topics/genai-audit-xsiam-forwarder-openai-audit"
      }'
```

Or pull the audit_topics straight from the parent stack:

```bash
TOPICS=$(cd ../../../terraform/gcp && terraform output -json xsiam_audit_topics)
terraform apply \
  -var "project_id=<your-gcp-project>" \
  -var "audit_topics=$TOPICS"
```

After apply, the audit feed messages start streaming into BigQuery.

Set up Looker Studio: see [`dashboards/looker_studio.md`](dashboards/looker_studio.md).

## Deploy — AWS

```bash
cd analytics/terraform/aws
terraform init
terraform apply \
  -var "audit_bucket=<from parent: terraform output audit_bucket>" \
  -var 'vendor_keys=["anthropic", "openai"]'
```

After apply, you can query immediately via the Athena console (select
the workgroup `genai-audit-xsiam-forwarder-audit`).

Set up QuickSight: see [`dashboards/quicksight.md`](dashboards/quicksight.md).

## Operational notes

- **Where the data lives:** the parent forwarder stack writes audit
  events to S3 (AWS) or Pub/Sub topics (GCP). The analytics stack
  layers on top — it does NOT duplicate or re-fetch from the vendor
  APIs. Same operational guarantees as the parent.

- **Latency:** GCP Pub/Sub → BQ subscriptions deliver in seconds. AWS
  Athena queries S3 directly — no ingest delay, just query latency.

- **Schema drift:** Glue tables use schema-on-read (mostly STRING
  columns + JSON extraction at query time) so vendor-side schema
  changes don't break tables. BigQuery raw tables store the message
  body as a single STRING column; same logic.

- **Retention:** BigQuery tables auto-expire partitions per
  `var.table_expiration_days` (default 365). S3 audit objects retain
  per the parent stack's `bucket_object_retention_days`. Athena
  results bucket has its own short-lived expiry.

## Privacy & access control

The analytics tier sees the SAME data as XSIAM. If the parent stack's
content feeds (`anthropic_chats`, `openai_conversations`, Cowork OTel)
are enabled, this tier carries prompt/response transcripts.

Apply the same data-classification controls as the XSIAM datasets:

- **GCP:** `bigquery.dataViewer` on the dataset only to authorized
  responders. Row-level security if you need to scope by vendor or
  organization.
- **AWS:** attach the `athena_query_iam_policy_arn` only to authorized
  principals. Lake Formation column masking if you need finer-grained
  control.

See [`docs/security.md`](../docs/security.md) for the threat model and
data-classification matrix.
