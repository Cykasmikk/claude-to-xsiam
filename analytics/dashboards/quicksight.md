# QuickSight dashboard setup

QuickSight has Terraform support but the dashboard JSON definitions
break across QS minor releases. Manual setup is more durable. Cost is
the gate: **$18-24/user/month** for QuickSight licensing — if you
don't have it, point Tableau / Metabase / Looker at the Athena
workgroup instead with the same queries.

## Prerequisites

- Apply [analytics/terraform/aws](../terraform/aws/) — that creates
  the Glue catalog, per-vendor tables, Athena workgroup, results
  bucket, and the IAM policy QuickSight needs.
- An Active QuickSight subscription (Standard or Enterprise) in the
  same region as the audit bucket.

## Step 1 — grant QuickSight access to the resources

1. **QuickSight Console → Manage QuickSight → Security & permissions →
   QuickSight access to AWS services**
2. Enable:
   - **Amazon S3** → grant access to the parent stack's audit bucket
     and the analytics stack's `athena_results_bucket`
   - **Amazon Athena** → grant access to the workgroup
     `genai-audit-xsiam-forwarder-audit`
3. Attach the `athena_query_iam_policy_arn` Terraform output to the
   QuickSight service role for tighter scoping.

## Step 2 — create datasets per query

For each `*_athena.sql` you want a chart over:

1. **Datasets → New dataset → Athena**
2. Data source name: `genai-audit` (workgroup:
   `genai-audit-xsiam-forwarder-audit`)
3. **Use custom SQL** → paste the query from
   [`../sql/01_volume_by_vendor_athena.sql`](../sql/01_volume_by_vendor_athena.sql) etc.
4. **Edit/Preview** → check the result, **Save & visualize**

## Step 3 — recommended dashboards

Same three-page layout as the [Looker Studio walkthrough](looker_studio.md#step-2--wire-dashboards).
Visuals translate 1:1 to QuickSight chart types:

| Looker Studio visual | QuickSight equivalent |
|---|---|
| Time-series line chart | Line chart |
| Big-number scorecard | KPI |
| Sortable table | Table |
| Bar chart | Horizontal/vertical bar chart |
| Geo map | Filled map (with built-in QS IP geo enrichment via the lookup tables) |

QuickSight has slightly better built-in geo capabilities than Looker
Studio (no upstream IP→geo enrichment needed for the
`05_actor_geo_distribution` dashboard).

## Step 4 — refresh and share

- **Datasets** → SPICE refresh schedule (recommended for tables that
  power dashboards — keeps query cost predictable). Default: hourly.
- **Direct query** mode is also supported but each dashboard load
  scans the underlying S3. At audit volume that's cents, but watch it
  on content feeds.
- **Share** → assign QuickSight users / groups Reader or Author roles
  on the dashboard. **Author roles cost more** (Standard tier doesn't
  have Author seats).

## Cost projection

For a small SOC (5 readers + 1 author):

```
1 author × $24/mo  = $24
5 readers × $5/mo  = $25  (Reader Capacity pricing on Enterprise)
Athena queries ≈ $0.50/mo (most are sub-MB scans)
─────────────────────────
Total ≈ $50/mo
```

Standard tier (no Reader Capacity, all-Author): 6 × $18 = $108/mo.
Enterprise Reader Capacity is materially cheaper for read-heavy
audiences.

## Alternatives if QuickSight licensing is a blocker

The same Athena workgroup is queryable by:

- **Tableau** (with the Athena ODBC driver) — your existing licenses
- **Metabase** (open-source) — point at Athena via JDBC
- **Looker Cloud** — uses the JDBC driver
- **Grafana** (open-source + AWS Data Source plugin) — works for
  time-series visuals; weaker for tables

The SQL queries in [`../sql/`](../sql/) work unchanged across all of
the above — Athena's query engine does the work.
