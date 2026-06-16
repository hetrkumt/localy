# ========================================================================
# Loki IRSA ??OIDC Zero-Trust Lock + S3 Blast-Radius Isolation
# ========================================================================

# -------------------------------------------------------------------------
# 1. S3 ?묎렐 ?뺤콉 + KMS ?붾났?명솕 (??컻 諛섍꼍 寃⑸━: Loki ?꾩슜 踰꾪궥 諛??ㅻ쭔)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid    = "AllowListLokiBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.loki_logs.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpc"
      values   = [data.aws_ssm_parameter.vpc_id.value]
    }
  }

  statement {
    sid    = "AllowObjectOpsOnLokiPrefix"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload"
    ]
    resources = [
      "${aws_s3_bucket.loki_logs.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpc"
      values   = [data.aws_ssm_parameter.vpc_id.value]
    }
  }

  statement {
    sid    = "AllowKMSCrypto"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = [
      aws_kms_key.loki_s3.arn
    ]
  }
}

# -------------------------------------------------------------------------
# 2. OIDC Trust Policy (?쒕줈 ?몃윭?ㅽ듃: observability/loki SA留?
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "loki_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.oidc_provider_arn.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:sub"
      values   = ["system:serviceaccount:observability:loki"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------------------
# 3. IAM Role + Policy 寃곗냽
# -------------------------------------------------------------------------
resource "aws_iam_role" "loki" {
  name               = "${module.global.env_name}-loki-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.loki_assume_role.json

  tags = {
    Name        = "${module.global.env_name}-loki-irsa-role"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-s3-irsa"
  }
}

resource "aws_iam_role_policy" "loki_s3" {
  name   = "${module.global.env_name}-loki-s3-policy"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_s3.json
}

# -------------------------------------------------------------------------
# 4. Output ??Loki Helm values ?곕룞??# -------------------------------------------------------------------------
output "loki_irsa_arn" {
  description = "Loki ServiceAccount??annotation?쇰줈 遺李⑺븷 IRSA Role ARN"
  value       = aws_iam_role.loki.arn
}
