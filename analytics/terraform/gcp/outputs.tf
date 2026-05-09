output "dataset_id" {
  description = "BigQuery dataset id for Looker Studio data sources."
  value       = google_bigquery_dataset.audit.dataset_id
}

output "raw_tables" {
  description = "Per-vendor raw-events tables. Use these as the data source for ad-hoc Looker Studio dashboards, or write a scheduled query to materialize a flattened per-vendor table."
  value       = { for k, t in google_bigquery_table.raw : k => "${var.project_id}.${t.dataset_id}.${t.table_id}" }
}

output "bq_subscriptions" {
  description = "Pub/Sub subscriptions writing to BigQuery (separate from the XSIAM-bound subs in the parent stack)."
  value       = { for k, s in google_pubsub_subscription.to_bq : k => s.id }
}
