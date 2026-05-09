output "glue_database" {
  description = "Glue Data Catalog database name. Use this in QuickSight / Athena data source connections."
  value       = aws_glue_catalog_database.audit.name
}

output "glue_tables" {
  description = "Per-vendor Glue table names (one Athena table per audit feed)."
  value       = { for k, t in aws_glue_catalog_table.vendor : k => t.name }
}

output "athena_workgroup" {
  description = "Athena workgroup. Direct queries here; the workgroup enforces the dedicated results bucket."
  value       = aws_athena_workgroup.audit.name
}

output "athena_results_bucket" {
  description = "S3 bucket where Athena query results land (auto-expired after var.athena_results_retention_days)."
  value       = aws_s3_bucket.athena_results.bucket
}

output "athena_query_iam_policy_arn" {
  description = "IAM policy ARN to attach to whatever principal will run Athena queries (console user, QuickSight role, CI role, etc)."
  value       = aws_iam_policy.athena_query.arn
}
