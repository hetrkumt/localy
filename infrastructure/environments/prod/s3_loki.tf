# ========================================================================
#    Loki Cold Storage — S3 Core Vault, Lifecycle Incinerator, PAB Shield
# ========================================================================

data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  # Terraform/CI 실행 Role·User — StrictDeny VPCE·Principal 조건에서 ArnNotEquals 예외
  s3_policy_bypass_principal_arns = distinct(compact(concat(
    var.s3_bucket_policy_bypass_principal_arns,
    [
      data.aws_iam_session_context.current.issuer_arn,
      data.aws_caller_identity.current.arn,
    ],
  )))
}

resource "aws_s3_bucket" "loki_logs" {
  bucket = "${var.env_name}-eks-loki-logs-vault"

  # 🚨 [임시 추가] 버킷 안에 로그 데이터가 남아 있어도 강제로 모조리 소각 (테스트 환경 용이성)
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

  # 1. 과거 버전 3일 뒤 소각 (해커의 크립토 슈레딩 방어용 골든타임)
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.loki_logs,
  ]
}

resource "aws_s3_bucket_lifecycle_configuration" "loki_logs" {
  bucket = aws_s3_bucket.loki_logs.id

  # 2. [FinOps] Current Version — 90일 영구 소각, delete marker 청소 (IA 전환 없음)
  rule {
    id     = "current-version-expiration"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
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
    aws_s3_bucket_object_lock_configuration.loki_logs,
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
# Zero-Trust — VPCE + Loki IRSA 이중 검증 (Terraform/CI Role ArnNotEquals 예외)
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
    sid    = "AllowLokiIRSAViaVpcEndpointOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.loki.arn]
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
      values   = [aws_iam_role.loki.arn]
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
