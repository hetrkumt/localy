# ========================================================================
#    L1 Network SSM Parameters - 타 레이어 간접 참조용 배관 선언
# ========================================================================

resource "aws_ssm_parameter" "vpc_id" {
  name        = local.ssm_paths["vpc_id"]
  type        = "String"
  value       = module.network.vpc_id
  description = "The VPC ID of the localy network backbone"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "private_subnets" {
  name        = local.ssm_paths["private_subnets"]
  type        = "StringList"
  value       = join(",", module.network.private_subnets)
  description = "The list of private subnet IDs of the localy network backbone"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

# [긴급 보수] l3에서 RDS/Redis Subnet Group 생성을 위해 DB 서브넷 파라미터 매립
resource "aws_ssm_parameter" "database_subnets" {
  name        = local.ssm_paths["database_subnets"]
  type        = "StringList"
  value       = join(",", module.network.database_subnets)
  description = "The list of database subnet IDs of the localy network backbone"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

# [신규 추가] Pod 전용 서브넷 (l2-eks의 CNI 설정에 참조됨)
resource "aws_ssm_parameter" "pod_subnets" {
  name        = local.ssm_paths["pod_subnets"]
  type        = "StringList"
  value       = join(",", module.network.pod_subnets)
  description = "The list of pod subnet IDs of the localy secondary CIDR network"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "s3_vpc_endpoint_id" {
  name        = local.ssm_paths["s3_vpc_endpoint_id"]
  type        = "String"
  value       = module.network.s3_vpc_endpoint_id
  description = "The S3 Gateway VPC Endpoint ID for zero-trust S3 bucket policies"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

# [신규 추가] 공용 ALB 보안그룹 ID (TargetGroupBinding 생성 시 노드 SG 인바운드 규칙 등록용)
resource "aws_ssm_parameter" "shared_alb_sg_id" {
  name        = local.ssm_paths["shared_alb_sg_id"]
  type        = "String"
  value       = module.network.shared_alb_sg_id
  description = "The Shared ALB Security Group ID for EKS TargetGroupBinding ingress config"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

# -----------------------------------------------------------------------------
# [신규 추가] 마이크로서비스 ALB Target Group ARN (GitOps 치환 스크립트용)
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "eks_tg_arn" {
  name        = local.ssm_paths["eks_tg_arn"]
  type        = "String"
  value       = module.network.target_groups_map["eks"]
  description = "EKS Edge Gateway ALB Target Group ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "user_tg_arn" {
  name        = local.ssm_paths["user_tg_arn"]
  type        = "String"
  value       = module.network.target_groups_map["user"]
  description = "User Service ALB Target Group ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "cart_tg_arn" {
  name        = local.ssm_paths["cart_tg_arn"]
  type        = "String"
  value       = module.network.target_groups_map["cart"]
  description = "Cart Service ALB Target Group ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "payment_tg_arn" {
  name        = local.ssm_paths["payment_tg_arn"]
  type        = "String"
  value       = module.network.target_groups_map["pay"]
  description = "Payment Service ALB Target Group ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}

resource "aws_ssm_parameter" "store_tg_arn" {
  name        = local.ssm_paths["store_tg_arn"]
  type        = "String"
  value       = module.network.target_groups_map["store"]
  description = "Store Service ALB Target Group ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l1-network"
  }
}
