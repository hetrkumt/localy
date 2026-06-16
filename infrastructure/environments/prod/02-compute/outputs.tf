# ========================================================================
# SSM Parameter Store — 2계층 → 3계층(IAM & Workloads) 우체통
# SecureString 미사용: EKS 인증 메타데이터는 클러스터 식별·연결 정보
# ========================================================================

resource "aws_ssm_parameter" "cluster_name" {
  name        = "/localy/prod/compute/cluster_name"
  description = "Localy Prod - EKS cluster name exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.cluster_name
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "eks_endpoint" {
  name        = "/localy/prod/compute/eks_endpoint"
  description = "Localy Prod - EKS API server endpoint exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.cluster_endpoint
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "eks_ca" {
  name        = "/localy/prod/compute/eks_ca"
  description = "Localy Prod - EKS cluster CA certificate (base64) exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.cluster_certificate_authority_data
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "oidc_provider_arn" {
  name        = "/localy/prod/compute/oidc_provider_arn"
  description = "Localy Prod - EKS OIDC provider ARN for IRSA exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.oidc_provider_arn
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "oidc_issuer_url" {
  name        = "/localy/prod/compute/oidc_issuer_url"
  description = "Localy Prod - EKS OIDC issuer URL for IRSA trust policy exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.cluster_oidc_issuer_url
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "kms_key_arn" {
  name        = "/localy/prod/compute/kms_key_arn"
  description = "Localy Prod - EKS secrets encryption KMS key ARN exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.kms_key_arn
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "ebs_csi_role_name" {
  name        = "/localy/prod/compute/ebs_csi_role_name"
  description = "Localy Prod - EBS CSI IRSA IAM role name (created by EKS module) exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.ebs_csi_role_name
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "ebs_csi_role_arn" {
  name        = "/localy/prod/compute/ebs_csi_role_arn"
  description = "Localy Prod - EBS CSI IRSA IAM role ARN (created by EKS module) exported for Layer 03 IAM & Workloads"
  type        = "String"
  value       = module.eks.ebs_csi_role_arn
  tags        = module.global.common_tags
}
