# ========================================================================
#    L2 EKS SSM Parameters - 타 레이어 및 GitOps 간접 참조용 배관 선언
# ========================================================================

resource "aws_ssm_parameter" "eks_cluster_name" {
  name        = local.ssm_paths["eks_cluster_name"]
  type        = "String"
  value       = module.eks.cluster_name
  description = "The EKS Cluster Name"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "eks_cluster_endpoint" {
  name        = local.ssm_paths["eks_cluster_endpoint"]
  type        = "String"
  value       = module.eks.cluster_endpoint
  description = "The EKS Cluster API Endpoint"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "eks_cluster_ca_data" {
  name        = local.ssm_paths["eks_cluster_ca_data"]
  type        = "String"
  value       = module.eks.cluster_certificate_authority_data
  description = "The EKS Cluster CA Certificate Data"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "eks_oidc_provider" {
  name        = local.ssm_paths["eks_oidc_provider"]
  type        = "String"
  value       = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  description = "The EKS Cluster OIDC Provider URL (without scheme)"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "eks_oidc_provider_arn" {
  name        = local.ssm_paths["eks_oidc_provider_arn"]
  type        = "String"
  value       = module.eks.oidc_provider_arn
  description = "The EKS Cluster OIDC Provider ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

# --- IRSA IAM Role ARNs ---

resource "aws_ssm_parameter" "role_cert_manager_arn" {
  name        = local.ssm_paths["role_cert_manager_arn"]
  type        = "String"
  value       = aws_iam_role.prod_certmanager_irsa_role.arn
  description = "Cert-Manager IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_loki_arn" {
  name        = local.ssm_paths["role_loki_arn"]
  type        = "String"
  value       = aws_iam_role.loki.arn
  description = "Loki IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_karpenter_controller_arn" {
  name        = local.ssm_paths["role_karpenter_controller_arn"]
  type        = "String"
  value       = module.eks.karpenter_controller_role_arn
  description = "Karpenter Controller IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_karpenter_node_role_name" {
  name        = local.ssm_paths["role_karpenter_node_role_name"]
  type        = "String"
  value       = module.eks.karpenter_node_iam_role_name
  description = "Karpenter Node IAM Role Name"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "karpenter_interruption_queue_name" {
  name        = local.ssm_paths["karpenter_interruption_queue_name"]
  type        = "String"
  value       = module.eks.karpenter_interruption_queue_name
  description = "Karpenter Interruption SQS Queue Name"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_alb_controller_arn" {
  name        = local.ssm_paths["role_alb_controller_arn"]
  type        = "String"
  value       = aws_iam_role.aws_lbc_iam_role.arn
  description = "AWS Load Balancer Controller IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_external_dns_arn" {
  name        = local.ssm_paths["role_external_dns_arn"]
  type        = "String"
  value       = aws_iam_role.prod_externaldns_irsa_role.arn
  description = "External-DNS IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_ebs_csi_arn" {
  name        = local.ssm_paths["role_ebs_csi_arn"]
  type        = "String"
  value       = module.eks.ebs_csi_role_arn
  description = "EBS CSI Driver IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_grafana_arn" {
  name        = local.ssm_paths["role_grafana_arn"]
  type        = "String"
  value       = module.eks.grafana_irsa_arn
  description = "Grafana IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_alarm_pipeline_sns_arn" {
  name        = local.ssm_paths["role_alarm_pipeline_sns_arn"]
  type        = "String"
  value       = aws_iam_role.alarm_pipeline_sns.arn
  description = "Alertmanager SNS Publisher IRSA Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_eso_controller_arn" {
  name        = local.ssm_paths["role_eso_controller_arn"]
  type        = "String"
  value       = module.eks.eso_controller_role_arn
  description = "ESO Controller IRSA IAM Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}

resource "aws_ssm_parameter" "role_workload_pod_identity_arn" {
  name        = local.ssm_paths["role_workload_pod_identity_arn"]
  type        = "String"
  value       = module.eks.workload_pod_identity_role_arn
  description = "Workload EKS Pod Identity IAM Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l2-eks"
  }
}
