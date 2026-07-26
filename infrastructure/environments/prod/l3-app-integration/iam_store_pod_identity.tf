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
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "store_s3" {
  role       = aws_iam_role.store_service.name
  policy_arn = aws_iam_policy.store_s3_access.arn
}

# Attach shared MSK + RDS IAM Auth policies (same as generic workload role)
resource "aws_iam_role_policy_attachment" "store_msk" {
  role       = aws_iam_role.store_service.name
  policy_arn = aws_iam_policy.workload_msk_access.arn
}

resource "aws_iam_role_policy_attachment" "store_rds_iam" {
  role       = aws_iam_role.store_service.name
  policy_arn = aws_iam_policy.workload_rds_iam_access.arn
}

# 3. EKS Pod Identity Association (K8s SA ↔ IAM Role 바인딩)
resource "aws_eks_pod_identity_association" "store_service" {
  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = "store-service"
  service_account = "store-service-sa"
  role_arn        = aws_iam_role.store_service.arn
}
