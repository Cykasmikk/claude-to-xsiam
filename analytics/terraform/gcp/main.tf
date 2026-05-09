data "google_project" "this" {
  project_id = var.project_id
}

# ─── BigQuery dataset (one shared dataset for all vendors) ────────────────
resource "google_bigquery_dataset" "audit" {
  # checkov:skip=CKV_GCP_81:Google-managed encryption is sufficient for the SOC analytics baseline. CSEK adds key-rotation ops overhead without quantifiable security benefit; the same audit data is also stored in XSIAM under its own controls.
  dataset_id  = replace("${var.name_prefix}_audit", "-", "_")
  description = "GenAI vendor audit events from the polling forwarder. One table per vendor; populated by Pub/Sub → BigQuery subscriptions."
  location    = var.dataset_location

  # Partition expiration applies to every partitioned table in the dataset
  # unless overridden at the table level.
  default_partition_expiration_ms = (
    var.table_expiration_days > 0
    ? var.table_expiration_days * 24 * 60 * 60 * 1000
    : null
  )

  # Audit log access — record who reads the audit data itself.
  delete_contents_on_destroy = false
}

# ─── Per-vendor raw-events tables ─────────────────────────────────────────
# Pub/Sub BigQuery subscription requires a pre-existing table with a schema
# matching its delivery contract. We use the "Use topic schema" model
# disabled — meaning the subscription writes the message body as a `data`
# column (BYTES) plus subscription metadata. Operators can run a daily
# scheduled query to flatten `data` into a structured per-vendor table for
# Looker Studio.
#
# Schema reference (Pub/Sub → BigQuery defaults):
#   subscription_name : STRING — name of the subscription
#   message_id        : STRING — Pub/Sub message id (unique)
#   publish_time      : TIMESTAMP — when Pub/Sub received the message
#   data              : STRING — raw message body (JSON event)
#   attributes        : STRING — JSON-stringified message attributes
resource "google_bigquery_table" "raw" {
  # checkov:skip=CKV_GCP_80:Google-managed encryption is sufficient. CMK adds key-rotation ops overhead without quantifiable benefit at audit-log volumes.
  # checkov:skip=CKV_GCP_121:deletion protection blocks `terraform destroy` on these analytics tables. Source-of-truth is the parent stack's S3 / Pub-Sub buffer + XSIAM; a destroy + re-apply is acceptable for the analytics warehouse.
  for_each            = var.audit_topics
  dataset_id          = google_bigquery_dataset.audit.dataset_id
  table_id            = "raw_${replace(each.key, "-", "_")}"
  description         = "Raw Pub/Sub messages for the ${each.key} feed. Flatten via the materialize_${replace(each.key, "-", "_")} scheduled query."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }

  schema = jsonencode([
    {
      name = "subscription_name"
      type = "STRING"
      mode = "REQUIRED"
    },
    {
      name = "message_id"
      type = "STRING"
      mode = "REQUIRED"
    },
    {
      name = "publish_time"
      type = "TIMESTAMP"
      mode = "REQUIRED"
    },
    {
      name = "data"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "attributes"
      type = "STRING"
      mode = "NULLABLE"
    },
  ])
}

# ─── Pub/Sub BigQuery subscriptions on each audit topic ───────────────────
# Each subscription mirrors the parent stack's xsiam-bound subscription
# but writes to BigQuery instead of being polled by XSIAM. The parent
# stack's subscription is unaffected.
resource "google_pubsub_subscription" "to_bq" {
  for_each = var.audit_topics
  name     = "${var.name_prefix}-${each.key}-bq-analytics"
  topic    = each.value

  message_retention_duration = "${var.subscription_message_retention_seconds}s"
  retain_acked_messages      = false
  ack_deadline_seconds       = 60

  bigquery_config {
    table               = "${var.project_id}.${google_bigquery_dataset.audit.dataset_id}.${google_bigquery_table.raw[each.key].table_id}"
    use_topic_schema    = false
    write_metadata      = true
    drop_unknown_fields = false
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [
    google_bigquery_dataset_iam_member.pubsub_sa,
    google_bigquery_dataset_iam_member.pubsub_metadata,
  ]
}

# Pub/Sub service agent needs to write to the BigQuery table — grant on the
# project-level BigQuery Data Editor role scoped via a condition would be
# tighter, but Pub/Sub's BQ subscription IAM model expects the SA to have
# bigquery.dataEditor on the dataset. Scope by dataset.
resource "google_bigquery_dataset_iam_member" "pubsub_sa" {
  dataset_id = google_bigquery_dataset.audit.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Pub/Sub also needs metadataViewer on the dataset to see the table schema.
resource "google_bigquery_dataset_iam_member" "pubsub_metadata" {
  dataset_id = google_bigquery_dataset.audit.dataset_id
  role       = "roles/bigquery.metadataViewer"
  member     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

