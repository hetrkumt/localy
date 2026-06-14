# ========================================================================
# ChatOps Alarm Forensic Vault — S3 Zero-Trust Dump Bucket
#   Phase 3: 알람 원본 덤프 포렌식 볼트 (VPCE 격리 + 90일 소각 + SSE-S3)
# ========================================================================

resource "aws_s3_bucket" "chatops_alarm_dump" {
  bucket = "${var.env_name}-eks-chatops-alarm-dump-vault"

  tags = {
    Name        = "${var.env_name}-eks-chatops-alarm-dump-vault"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-alarm-forensic-vault"
  }
}

resource "aws_s3_bucket_public_access_block" "chatops_alarm_dump" {
  bucket = aws_s3_bucket.chatops_alarm_dump.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "chatops_alarm_dump" {
  bucket = aws_s3_bucket.chatops_alarm_dump.id

  rule {
    id     = "alarm-dump-90-day-incinerator"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "chatops_alarm_dump" {
  bucket = aws_s3_bucket.chatops_alarm_dump.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ========================================================================
# Zero-Trust — S3 Gateway VPCE + Lambda Principal Lock (module.network → Phase 1)
# ========================================================================

data "aws_iam_policy_document" "chatops_alarm_dump" {
  statement {
    sid    = "AllowS3AccessViaS3VpcEndpointOnly"
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
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:sourceVpce"
      values   = [module.network.s3_vpc_endpoint_id]
    }
  }

  statement {
    sid    = "AllowChatOpsLambdaViaVpcEndpointOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.alarm_pipeline_lambda.arn]
    }

    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = [
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:sourceVpce"
      values   = [module.network.s3_vpc_endpoint_id]
    }
  }

  statement {
    sid    = "AllowDispatchForensicPutWithoutVpcEndpoint"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.chatops_dispatch_lambda.arn]
    }

    actions = [
      "s3:PutObject",
    ]

    resources = [
      "${aws_s3_bucket.chatops_alarm_dump.arn}/forensic/*",
    ]
  }

  statement {
    sid    = "AllowJitAuthForensicReadWithoutVpcEndpoint"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.chatops_jit_auth_lambda.arn]
    }

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/forensic/*",
    ]
  }

  statement {
    sid    = "StrictDenyOutsideVpcEndpoint"
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
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:sourceVpce"
      values   = [module.network.s3_vpc_endpoint_id]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values = concat(
        local.s3_policy_bypass_principal_arns,
        [
          aws_iam_role.chatops_jit_auth_lambda.arn,
          aws_iam_role.chatops_dispatch_lambda.arn,
        ],
      )
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalIsAWSService"
      values   = ["true"]
    }
  }

  statement {
    sid    = "StrictDenyNonChatOpsPrincipal"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = [
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values = [
        aws_iam_role.alarm_pipeline_lambda.arn,
        aws_iam_role.chatops_dispatch_lambda.arn,
      ]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.s3_policy_bypass_principal_arns
    }
  }
}

resource "aws_s3_bucket_policy" "chatops_alarm_dump" {
  bucket = aws_s3_bucket.chatops_alarm_dump.id
  policy = data.aws_iam_policy_document.chatops_alarm_dump.json
}
