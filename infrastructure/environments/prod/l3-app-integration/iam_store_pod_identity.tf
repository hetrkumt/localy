# ========================================================================
# Store Service — Dedicated Pod Identity Role & S3/KMS Policy (서비스 격리)
# ========================================================================

# 1. store-service 전용 Pod Identity Trust Policy Role
resource "aws_iam_role" "store_service" {
  name = "${var.env_name}-store-service-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      },
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_ssm_parameter.eks_oidc_provider_arn.value
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${data.aws_ssm_parameter.eks_oidc_provider.value}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${data.aws_ssm_parameter.eks_oidc_provider.value}:sub" = "system:serviceaccount:*:*-sa"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Service     = "store-service"
  }
}

# 2. S3 + KMS 최소 권한 정책 (와일드카드 s3:* 절대 금지)
#    [통제관 미세 교정] SecretsManager 권한 완전 삭제 — ESO가 시크릿 조회를 전담
resource "aws_iam_policy" "store_s3_access" {
  name        = "${var.env_name}-store-s3-access-policy"
  description = "Allows store-service pods to manage images in S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ObjectActions"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.store_images.arn}/*"
      },
      {
        Sid    = "AllowKMSDecryptForS3"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.store_s3.arn
      },
      # Secrets Manager read moved to path-scoped policy on
      # aws_iam_role.workload_service_irsa["store-service"] (Phase 7 correction).
    ]
  })
}

resource "aws_iam_role_policy_attachment" "store_s3" {
  role       = aws_iam_role.store_service.name
  policy_arn = aws_iam_policy.store_s3_access.arn
}

# Attach shared MSK + RDS to LEGACY store role retired — canonical bindings are on
# aws_iam_role.workload_service_irsa["store-service"] (iam_workload_per_service_irsa.tf).
# Keep S3 policy attachment on legacy role only so policy resource can still be referenced
# by store_irsa_s3; MSK/RDS duplicate attachments removed to shrink blast radius.

# 3. Pod Identity Association RETIRED — see iam_workload_per_service_irsa.tf
# Canonical role: prod-eks-store-service-irsa-role (SSM: .../apps/iam/store_service_role_arn)
# Legacy role aws_iam_role.store_service retained temporarily for S3 policy ARN reuse only.
