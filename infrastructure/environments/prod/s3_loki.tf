# ========================================================================
# Loki Cold Storage — S3 Core Vault, Lifecycle Incinerator, PAB Shield
# ========================================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "loki_logs" {
  bucket = "${var.env_name}-eks-loki-logs-bucket"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.env_name}-eks-loki-logs-bucket"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-cold-storage"
  }
}

resource "aws_s3_bucket_versioning" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  rule {
    id     = "noncurrent-version-expiration"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ========================================================================
# SSE-KMS Lock + FinOps S3 Bucket Key
# ========================================================================

resource "aws_kms_key" "loki_s3" {
  description             = "KMS key for Loki S3 bucket encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Name        = "${var.env_name}-loki-s3-kms"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-s3-encryption"
  }
}

resource "aws_kms_alias" "loki_s3" {
  name          = "alias/${var.env_name}-loki-s3-key"
  target_key_id = aws_kms_key.loki_s3.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.loki_s3.arn
    }

    bucket_key_enabled = true
  }
}

# ========================================================================
# Zero-Trust Checkpoint — S3 VPC Endpoint (Gateway) binding only
# ========================================================================

data "aws_iam_policy_document" "loki_logs" {
  statement {
    sid    = "AllowS3AccessViaS3VpcEndpoint"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = [
      aws_s3_bucket.loki_logs.arn,
      "${aws_s3_bucket.loki_logs.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:sourceVpce"
      values   = [module.network.s3_vpc_endpoint_id]
    }
  }

  statement {
    sid    = "DenyS3AccessNotViaS3VpcEndpoint"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = [
      aws_s3_bucket.loki_logs.arn,
      "${aws_s3_bucket.loki_logs.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [module.network.s3_vpc_endpoint_id]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [data.aws_caller_identity.current.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id
  policy = data.aws_iam_policy_document.loki_logs.json
}
