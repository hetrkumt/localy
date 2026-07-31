# ========================================================================
# Workload Pod Identity - RDS Secrets & MSK Access Policy Attachment
# ========================================================================

# 1. RDS Secrets Manager 읽기 권한 정책
resource "aws_iam_policy" "workload_secrets_access" {
  name        = "${var.env_name}-workload-secrets-access-policy"
  description = "Allows EKS Pod Identity workload to read RDS Secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Shared role retained as fallback only — path-scoped policies live on
        # per-service IRSA roles (iam_workload_per_service_irsa.tf).
        Resource = [
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:/localy/${var.env_name}/workload/*",
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:localy/${var.env_name}/workload/*"
        ]
      }
    ]
  })
}

# 2. MSK (Kafka) Access Policy (EKS Pod Identity용 IAM 기반 클러스터 제어 권한)
resource "aws_iam_policy" "workload_msk_access" {
  name        = "${var.env_name}-workload-msk-access-policy"
  description = "Allows EKS Pod Identity workload to publish/consume from MSK"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMSKConnectAndWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = [
          "arn:aws:kafka:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/${aws_msk_cluster.msk.cluster_name}/*",
          "arn:aws:kafka:ap-northeast-2:${data.aws_caller_identity.current.account_id}:topic/${aws_msk_cluster.msk.cluster_name}/*",
          "arn:aws:kafka:ap-northeast-2:${data.aws_caller_identity.current.account_id}:group/${aws_msk_cluster.msk.cluster_name}/*"
        ]
      }
    ]
  })
}

# 3. [SecOps] OIDC/EKS Role ARN으로부터 Role Name 동적 추출 및 정책 바인딩
locals {
  # 예: arn:aws:iam::123456789012:role/prod-eks-workload-pod-identity-role ➔ prod-eks-workload-pod-identity-role 추출
  workload_role_name = element(
    split("/", data.aws_ssm_parameter.role_workload_pod_identity_arn.value),
    length(split("/", data.aws_ssm_parameter.role_workload_pod_identity_arn.value)) - 1
  )
}

resource "aws_iam_role_policy_attachment" "workload_secrets" {
  role       = local.workload_role_name
  policy_arn = aws_iam_policy.workload_secrets_access.arn
}

resource "aws_iam_role_policy_attachment" "workload_msk" {
  role       = local.workload_role_name
  policy_arn = aws_iam_policy.workload_msk_access.arn
}

# 4. RDS IAM DB Auth 정책 생성 및 바인딩
resource "aws_iam_policy" "workload_rds_iam_access" {
  name        = "${var.env_name}-workload-rds-iam-access-policy"
  description = "Allows EKS Pod Identity workload to connect to RDS via IAM Auth"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.rds.resource_id}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "workload_rds_iam" {
  role       = local.workload_role_name
  policy_arn = aws_iam_policy.workload_rds_iam_access.arn
}
