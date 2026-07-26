# ========================================================================
#    Store Images — S3 Bucket, PAB Shield, SSE-KMS, Lifecycle, VPCE Lock
# ========================================================================

resource "aws_s3_bucket" "store_images" {
  bucket = "localy-store-images-${var.env_name}"

  force_destroy = false

  tags = {
    Name        = "localy-store-images-${var.env_name}"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "store-service-images"
  }
}

# 1. Zero-Trust 퍼블릭 액세스 전체 차단
resource "aws_s3_bucket_public_access_block" "store_images" {
  bucket = aws_s3_bucket.store_images.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# 2. SSE-KMS 암호화 + S3 Bucket Key (CMK → kms_store.tf)
resource "aws_s3_bucket_server_side_encryption_configuration" "store_images" {
  bucket = aws_s3_bucket.store_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.store_s3.arn
    }

    bucket_key_enabled = true
  }

  depends_on = [aws_kms_key.store_s3]
}

# 3. FinOps Lifecycle — 90일 후 IA 전환, 미완료 멀티파트 1일 후 소각
resource "aws_s3_bucket_lifecycle_configuration" "store_images" {
  bucket = aws_s3_bucket.store_images.id

  rule {
    id     = "transition-old-images"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ========================================================================
# Zero-Trust — VPCE + Store Pod Identity 이중 검증
# ========================================================================

data "aws_iam_policy_document" "store_images" {
  # Allow: VPC Endpoint 경유 트래픽만 허용
  statement {
    sid    = "AllowAccessFromVPCEndpointOnly"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      aws_s3_bucket.store_images.arn,
      "${aws_s3_bucket.store_images.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:sourceVpce"
      values   = [data.aws_ssm_parameter.s3_vpc_endpoint_id.value]
    }
  }

  # Deny: VPC Endpoint 미경유 + Admin/CI 바이패스 예외
  statement {
    sid    = "DenyAccessNotViaVPCEndpoint"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      aws_s3_bucket.store_images.arn,
      "${aws_s3_bucket.store_images.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [data.aws_ssm_parameter.s3_vpc_endpoint_id.value]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.s3_policy_bypass_principal_arns
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalIsAWSService"
      values   = ["true"]
    }
  }
}

resource "aws_s3_bucket_policy" "store_images" {
  bucket = aws_s3_bucket.store_images.id
  policy = data.aws_iam_policy_document.store_images.json
}
