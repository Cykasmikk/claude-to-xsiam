variable "region" {
  description = "AWS region (must match the parent forwarder stack's bucket region)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to Glue / Athena resources."
  type        = string
  default     = "genai-audit-xsiam-forwarder"
}

variable "audit_bucket" {
  description = "Name of the audit S3 bucket from the parent forwarder stack (terraform output audit_bucket)."
  type        = string
}

variable "vendor_keys" {
  description = <<-EOT
    Vendor keys present under the audit bucket — one Glue table per vendor
    is created. Match the parent stack's var.vendors keys.
  EOT
  type        = list(string)
  default     = ["anthropic", "anthropic_chats", "openai", "openai_conversations"]
  validation {
    condition     = length(var.vendor_keys) > 0
    error_message = "Provide at least one vendor key."
  }
}

variable "athena_results_retention_days" {
  description = "Lifecycle expiry on the Athena query-results bucket. Result objects are throwaway."
  type        = number
  default     = 30
}
