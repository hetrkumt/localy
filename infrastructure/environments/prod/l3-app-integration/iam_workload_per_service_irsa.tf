# ========================================================================
# Phase 7 Correction — Per-service IRSA / Pod Identity (1:1 SA mapping)
# Replaces shared workload-pod-identity-role for business microservices.
# Secrets Manager access is path-scoped: /localy/prod/workload/<service>/*
# ========================================================================

locals {
  workload_irsa_services = {
    order-service = {
      sa_name      = "order-service-sa"
      sm_prefixes  = ["/localy/${var.env_name}/workload/order-"]
      msk          = true
    }
    payment-service = {
      sa_name      = "payment-service-sa"
      sm_prefixes  = ["/localy/${var.env_name}/workload/payment-"]
      msk          = true
    }
    cart-service = {
      sa_name      = "cart-service-sa"
      sm_prefixes  = ["/localy/${var.env_name}/workload/cart-"]
      msk          = false
    }
    user-service = {
      sa_name     = "user-service-sa"
      sm_prefixes = ["/localy/${var.env_name}/workload/user-"]
      msk         = false
    }
    edge-service = {
      sa_name     = "edge-service-sa"
      sm_prefixes = ["/localy/${var.env_name}/workload/edge-"]
      msk         = false
    }
    store-service = {
      sa_name     = "store-service-sa"
      sm_prefixes = ["/localy/${var.env_name}/workload/store-"]
      msk         = true
    }
  }
}

resource "aws_iam_role" "workload_service_irsa" {
  for_each = local.workload_irsa_services

  name = "${data.aws_ssm_parameter.eks_cluster_name.value}-${each.key}-irsa-role"

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
            "${data.aws_ssm_parameter.eks_oidc_provider.value}:sub" = "system:serviceaccount:${each.key}:${each.value.sa_name}"
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Service     = each.key
    Phase       = "7-correction"
  }
}

resource "aws_iam_policy" "workload_service_secrets_read" {
  for_each = local.workload_irsa_services

  name        = "${data.aws_ssm_parameter.eks_cluster_name.value}-${each.key}-secrets-read-policy"
  description = "Least-privilege Secrets Manager read for ${each.key}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPathScopedSecretsRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = flatten([
          for prefix in each.value.sm_prefixes : [
            "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:${prefix}*",
            "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:${trimprefix(prefix, "/")}*"
          ]
        ])
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "workload_service_secrets_read" {
  for_each = local.workload_irsa_services

  role       = aws_iam_role.workload_service_irsa[each.key].name
  policy_arn = aws_iam_policy.workload_service_secrets_read[each.key].arn
}

resource "aws_iam_role_policy_attachment" "workload_service_msk" {
  for_each = {
    for k, v in local.workload_irsa_services : k => v if v.msk
  }

  role       = aws_iam_role.workload_service_irsa[each.key].name
  policy_arn = aws_iam_policy.workload_msk_access.arn
}

resource "aws_iam_role_policy_attachment" "workload_service_rds_iam" {
  for_each = local.workload_irsa_services

  role       = aws_iam_role.workload_service_irsa[each.key].name
  policy_arn = aws_iam_policy.workload_rds_iam_access.arn
}

# Store keeps S3/KMS from iam_store_pod_identity.tf — attach those policies to new IRSA role too
resource "aws_iam_role_policy_attachment" "store_irsa_s3" {
  role       = aws_iam_role.workload_service_irsa["store-service"].name
  policy_arn = aws_iam_policy.store_s3_access.arn
}

resource "aws_eks_pod_identity_association" "workload_service_irsa" {
  for_each = local.workload_irsa_services

  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = each.key
  service_account = each.value.sa_name
  role_arn        = aws_iam_role.workload_service_irsa[each.key].arn
}

resource "aws_ssm_parameter" "workload_service_irsa_role_arn" {
  for_each = local.workload_irsa_services

  name        = "${local.ssm_prefix}/apps/iam/${replace(each.key, "-", "_")}_role_arn"
  description = "IRSA/Pod Identity role ARN for ${each.key}"
  type        = "String"
  value       = aws_iam_role.workload_service_irsa[each.key].arn

  tags = {
    Environment = var.env_name
    Service     = each.key
  }
}
