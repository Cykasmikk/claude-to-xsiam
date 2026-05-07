variable "project_id" {
  description = "GCP project to deploy the forwarder into."
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud Functions & Scheduler."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix applied to all resources."
  type        = string
  default     = "genai-audit-xsiam-forwarder"
}

variable "vendors" {
  description = <<-EOT
    Map of vendor name → vendor-specific NON-SENSITIVE config. Each entry
    creates a dedicated Cloud Function, Cloud Scheduler trigger, audit
    Pub/Sub topic, XSIAM-bound subscription, secret, and IAM bindings.

    Supported vendor keys: "anthropic", "openai".

    API keys are passed separately via var.api_keys (sensitive). Terraform
    forbids sensitive values as for_each keys, so they're split.
  EOT
  type = map(object({
    schedule_minutes         = optional(number, 5)
    initial_lookback_minutes = optional(number, 60)
  }))

  validation {
    condition     = alltrue([for k in keys(var.vendors) : contains(["anthropic", "openai"], k)])
    error_message = "vendors map keys must be one of: anthropic, openai."
  }
  validation {
    condition     = length(var.vendors) > 0
    error_message = "Provide at least one vendor in var.vendors."
  }
}

variable "api_keys" {
  description = <<-EOT
    Map of vendor name → API key. Keys must match those in var.vendors.

    Anthropic: sk-ant-admin01-... (Admin key) or sk-ant-api01-... (Compliance).
    OpenAI:    sk-admin-...
  EOT
  type        = map(string)
  sensitive   = true

  validation {
    condition     = alltrue([for k in keys(var.api_keys) : contains(["anthropic", "openai"], k)])
    error_message = "api_keys map keys must be one of: anthropic, openai."
  }
}

variable "subscription_message_retention_seconds" {
  description = "Retention on each XSIAM-bound subscription. Default: 7 days (Pub/Sub max)."
  type        = number
  default     = 604800
}
