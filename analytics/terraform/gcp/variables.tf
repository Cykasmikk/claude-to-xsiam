variable "project_id" {
  description = "GCP project (same as the parent forwarder stack)."
  type        = string
}

variable "region" {
  description = "GCP region for the BigQuery dataset."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix applied to BigQuery / IAM resources. Match the parent stack for consistency."
  type        = string
  default     = "genai-audit-xsiam-forwarder"
}

variable "audit_topics" {
  description = <<-EOT
    Map of vendor key → audit Pub/Sub topic id. Take from the parent
    forwarder stack's `xsiam_audit_topics` output:

      audit_topics = terraform output -json -state=../../terraform/gcp/terraform.tfstate xsiam_audit_topics

    Example:
      {
        anthropic            = "projects/my-project/topics/genai-audit-xsiam-forwarder-anthropic-audit"
        anthropic_chats      = "projects/my-project/topics/genai-audit-xsiam-forwarder-anthropic-chats-audit"
        openai               = "projects/my-project/topics/genai-audit-xsiam-forwarder-openai-audit"
        openai_conversations = "projects/my-project/topics/genai-audit-xsiam-forwarder-openai_conversations-audit"
      }
  EOT
  type        = map(string)
}

variable "dataset_location" {
  description = "BigQuery dataset location (multi-region or specific region). 'US' or 'EU' is typical."
  type        = string
  default     = "US"
}

variable "table_expiration_days" {
  description = <<-EOT
    Default partition expiration for the per-vendor raw-events tables.
    Audit data per Anthropic Compliance API has 6yr server-side retention;
    a 365-day BigQuery retention typically aligns with SOC-2 / ISO. Set 0
    for indefinite (no auto-delete).
  EOT
  type        = number
  default     = 365
}

variable "subscription_message_retention_seconds" {
  description = "Retention on the BQ-bound subscription. Matches the Pub/Sub max of 7 days."
  type        = number
  default     = 604800
}
