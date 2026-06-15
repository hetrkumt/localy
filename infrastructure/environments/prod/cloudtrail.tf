# ========================================================================
# CloudTrail — Loki Vault Data Events Precision Audit (FinOps Guarded)
# ========================================================================

data "aws_caller_identity" "cloudtrail" {}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${var.env_name}-eks-cloudtrail-audit-logs"

  tags = {
    Name        = "${var.env_name}-eks-cloudtrail-audit-logs"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "cloudtrail-audit-logs"
  }
   
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "cloudtrail-log-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_logs_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:GetBucketAcl"]

    resources = [
      aws_s3_bucket.cloudtrail_logs.arn
    ]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.cloudtrail.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs_bucket.json
}

resource "aws_cloudtrail" "loki_vault_data_events" {
  name                          = "${var.env_name}-loki-vault-data-events-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_logging                = true
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "LokiVaultObjectDataEvents"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.loki_logs.arn}/"]
    }

    field_selector {
      field  = "eventName"
      equals = ["GetObject", "PutObject", "DeleteObject"]
    }

    field_selector {
      field = "userIdentity.arn"
      not_starts_with = [
        format(
          "arn:aws:sts::%s:assumed-role/%s/",
          data.aws_caller_identity.cloudtrail.account_id,
          aws_iam_role.loki.name
        )
      ]
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}
