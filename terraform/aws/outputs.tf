output "lambda_function_names" {
  description = "Per-vendor Lambda function names."
  value       = { for k, fn in aws_lambda_function.forwarder : k => fn.function_name }
}

output "log_groups" {
  description = "Per-vendor CloudWatch log group names."
  value       = { for k, lg in aws_cloudwatch_log_group.lambda : k => lg.name }
}

output "state_table" {
  value = aws_dynamodb_table.state.name
}

# ─── XSIAM data source onboarding values ──────────────────────────────────
output "xsiam_role_arn" {
  description = "Single IAM role assumed by XSIAM for all vendors."
  value       = aws_iam_role.xsiam.arn
}

output "xsiam_external_id" {
  description = "External ID required for XSIAM to assume the ingest role."
  value       = random_uuid.xsiam_external_id.result
  sensitive   = true
}

output "xsiam_sqs_urls" {
  description = "Per-vendor SQS queue URL — configure one XSIAM data source per vendor pointing at its queue."
  value       = { for k, q in aws_sqs_queue.audit : k => q.url }
}

output "audit_bucket" {
  description = "Shared S3 bucket. Vendor objects are under /<vendor>/ prefixes."
  value       = aws_s3_bucket.audit.bucket
}
