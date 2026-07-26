# ========================================================================
# Loki IRSA — OIDC Zero-Trust Lock + S3 Blast-Radius Isolation
# ========================================================================

# -------------------------------------------------------------------------
# 1. S3 접근 정책 + KMS 암복호화 (폭발 반경 격리: Loki 전용 버킷 및 키만)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "loki_s3" {
  statement {
    sid    = "AllowListLokiBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.env_name}-eks-loki-logs-vault",
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
      "arn:aws:s3:::${var.env_name}-eks-loki-logs-vault/*",
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
      "*"
    ]
  }
}

# -------------------------------------------------------------------------
# 2. OIDC Trust Policy (제로 트러스트: loki 네임스페이스의 loki SA만)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "loki_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      # [핫픽스 2] OIDC 네임스페이스 매핑 불일치 패치 (observability -> loki)
      values = ["system:serviceaccount:loki:loki"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------------------
# 3. IAM Role + Policy 결속
# -------------------------------------------------------------------------
resource "aws_iam_role" "loki" {
  name               = "${var.env_name}-loki-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.loki_assume_role.json

  tags = {
    Name        = "${var.env_name}-loki-irsa-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-s3-irsa"
  }
}

resource "aws_iam_role_policy" "loki_s3" {
  name   = "${var.env_name}-loki-s3-policy"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_s3.json
}

# -------------------------------------------------------------------------
# 4. Output — Loki Helm values 연동용
# -------------------------------------------------------------------------
output "loki_irsa_arn" {
  description = "Loki ServiceAccount에 annotation으로 부착할 IRSA Role ARN"
  value       = aws_iam_role.loki.arn
}