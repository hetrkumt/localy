# ========================================================================
#    Loki Cold Storage — S3 Core Vault, Lifecycle Incinerator, PAB Shield
# ========================================================================

resource "aws_s3_bucket" "loki_logs" {
  bucket = "${var.env_name}-eks-loki-logs-vault"

  # 🚨 버킷 안에 로그 데이터가 남아 있어도 강제로 모조리 소각 (테스트 환경 용이성)
  force_destroy = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "${var.env_name}-eks-loki-logs-vault"
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

resource "aws_s3_bucket_object_lock_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  # 1. Object Lock 보존 기간 (규정 준수 모드 90일 보존)
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki_logs_lifecycle" {
  bucket = aws_s3_bucket.loki_logs.id

  # 2. [FinOps 핫픽스 5] Object Lock(90일)보다 확실히 길게 잡은 93일 소각 정책으로 충돌 회피
  rule {
    id     = "current-version-expiration"
    status = "Enabled"

    filter {}

    expiration {
      days = 93
    }
  }

  # 3. 미완료된 멀티파트 업로드 찌꺼기 소각
  rule {
    id     = "noncurrent-version-expiration"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.loki_logs,
  ]
}

resource "aws_s3_bucket_public_access_block" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ========================================================================
# SSE-KMS Lock + FinOps S3 Bucket Key (CMK → kms_loki.tf)
# ========================================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.loki_s3.arn
    }

    bucket_key_enabled = true
  }

  depends_on = [aws_kms_key.loki_s3]
}

# ========================================================================
# Zero-Trust — VPCE + Loki IRSA 이중 검증 (OIDC 역할 ARN은 SSM에서 동적 바인딩)
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
      values   = [data.aws_ssm_parameter.s3_vpc_endpoint_id.value]
    }
  }

  statement {
    sid    = "AllowLokiIRSAViaVpcEndpointOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_ssm_parameter.role_loki_arn.value]
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
      values   = [data.aws_ssm_parameter.s3_vpc_endpoint_id.value]
    }
  }

  statement {
    sid    = "DenyS3AccessNotViaS3VpcEndpoint"
    effect = "Deny"

    # [핫픽스 5] 누락되었던 principals 블록 지시자 복구 완료
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

  statement {
    sid    = "StrictDenyNonLokiPrincipal"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
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
      variable = "aws:PrincipalArn"
      values   = [data.aws_ssm_parameter.role_loki_arn.value]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.s3_policy_bypass_principal_arns
    }
  }
}

resource "aws_s3_bucket_policy" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id
  policy = data.aws_iam_policy_document.loki_logs.json
}
