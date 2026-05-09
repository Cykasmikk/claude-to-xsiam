data "aws_caller_identity" "current" {}

# ─── Athena query-results bucket ──────────────────────────────────────────
resource "aws_s3_bucket" "athena_results" {
  # checkov:skip=CKV_AWS_18:results bucket holds throwaway query-result CSVs; access logging would be redundant.
  # checkov:skip=CKV_AWS_144:cross-region replication doubles cost for ephemeral query results.
  # checkov:skip=CKV_AWS_145:AES-256 sufficient for query-result CSVs.
  # checkov:skip=CKV2_AWS_62:results bucket holds Athena query CSVs that auto-expire after var.athena_results_retention_days; downstream notification would be noise.
  bucket_prefix = "${var.name_prefix}-athena-results-"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-results"
    status = "Enabled"
    filter {}
    expiration {
      days = var.athena_results_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ─── Glue Data Catalog database ───────────────────────────────────────────
resource "aws_glue_catalog_database" "audit" {
  name        = replace("${var.name_prefix}_audit", "-", "_")
  description = "GenAI vendor audit events from the polling forwarder. One table per vendor over s3://${var.audit_bucket}/<vendor>/."
}

# ─── Per-vendor Glue tables ───────────────────────────────────────────────
# JSON SerDe over the gzipped JSON-lines objects the forwarder writes.
# Schema is intentionally permissive — most fields are STRING and the
# vendor-specific structure is preserved in `record` (anthropic) /
# `record` (openai) so operators can JSON_EXTRACT() at query time.
resource "aws_glue_catalog_table" "vendor" {
  for_each      = toset(var.vendor_keys)
  database_name = aws_glue_catalog_database.audit.name
  name          = replace(each.key, "-", "_")
  description   = "Audit events for the ${each.key} feed. Partitioned by yyyy/mm/dd/hh under s3://${var.audit_bucket}/${each.key}/."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"            = "json"
    "compressionType"           = "gzip"
    "EXTERNAL"                  = "TRUE"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2026,2030"
    "projection.year.digits"    = "4"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "projection.hour.type"      = "integer"
    "projection.hour.range"     = "0,23"
    "projection.hour.digits"    = "2"
    "storage.location.template" = "s3://${var.audit_bucket}/${each.key}/audit/$${year}/$${month}/$${day}/$${hour}/"
  }

  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }
  partition_keys {
    name = "hour"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${var.audit_bucket}/${each.key}/audit/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "ignore.malformed.json" = "true"
        "case.insensitive"      = "true"
      }
    }

    # All fields STRING — operators use json_extract / get_json_object at
    # query time. Schema-on-read keeps the table tolerant of vendor-side
    # field additions without requiring Terraform updates.
    columns {
      name = "id"
      type = "string"
    }
    columns {
      name = "created_at"
      type = "string"
    }
    columns {
      name = "type"
      type = "string"
    }
    columns {
      name = "actor"
      type = "string"
    }
    columns {
      name = "organization_id"
      type = "string"
    }
    columns {
      name = "raw_event"
      type = "string"
    }
  }
}

# ─── Athena workgroup (per-query cost control + dedicated results bucket)
resource "aws_athena_workgroup" "audit" {
  name        = "${var.name_prefix}-audit"
  description = "Workgroup for SOC analytics over the GenAI audit feeds."
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# ─── IAM policy: read audit bucket + write results bucket ─────────────────
# Operators attach this to whatever IAM principal will run Athena queries
# (a console user, a CI role, or a QuickSight integration role).
resource "aws_iam_policy" "athena_query" {
  name        = "${var.name_prefix}-athena-query"
  description = "Read audit bucket + write Athena results + Glue catalog access for SOC analytics."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAuditBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          "arn:aws:s3:::${var.audit_bucket}",
          "arn:aws:s3:::${var.audit_bucket}/*",
        ]
      },
      {
        Sid    = "WriteResultsBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
        ]
        Resource = [
          aws_s3_bucket.athena_results.arn,
          "${aws_s3_bucket.athena_results.arn}/*",
        ]
      },
      {
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.audit.name}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.audit.name}/*",
        ]
      },
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
        ]
        Resource = [aws_athena_workgroup.audit.arn]
      },
    ]
  })
}
