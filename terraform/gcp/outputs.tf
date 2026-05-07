output "function_names" {
  description = "Per-vendor Cloud Function names."
  value       = { for k, fn in google_cloudfunctions2_function.forwarder : k => fn.name }
}

output "scheduler_jobs" {
  description = "Per-vendor Scheduler tick jobs."
  value       = { for k, j in google_cloud_scheduler_job.tick : k => j.name }
}

# ─── XSIAM data source onboarding values ──────────────────────────────────
output "xsiam_audit_topics" {
  description = "Per-vendor Pub/Sub audit topics."
  value       = { for k, t in google_pubsub_topic.audit : k => t.id }
}

output "xsiam_audit_subscriptions" {
  description = "Per-vendor pull subscriptions XSIAM consumes — paste each into one XSIAM data source."
  value       = { for k, s in google_pubsub_subscription.xsiam : k => s.id }
}

output "xsiam_service_account_email" {
  description = <<-EOT
    Single SA XSIAM authenticates as for all vendors. Generate a JSON key
    out-of-band (gcloud iam service-accounts keys create) and paste into
    each XSIAM data source 'credentials' field. Do NOT add a
    google_service_account_key resource — keys in TF state are an audit
    smell.
  EOT
  value       = google_service_account.xsiam.email
}
