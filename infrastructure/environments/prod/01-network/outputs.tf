# ========================================================================
# SSM Parameter Store — 1계층 → 2/3계층 우체통 (Notion 설계도 6.1조)
# SecureString 미사용: VPC/서브넷/Endpoint ID는 비밀값이 아닌 인프라 식별자
# ========================================================================

resource "aws_ssm_parameter" "vpc_id" {
  name        = "/localy/prod/network/vpc_id"
  description = "Localy Prod - VPC ID exported for Layer 02 Compute"
  type        = "String"
  value       = module.network.vpc_id
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name        = "/localy/prod/network/private_subnet_ids"
  description = "Localy Prod - Private subnet IDs (JSON array) exported for Layer 02 Compute"
  type        = "String"
  value       = jsonencode(module.network.private_subnets)
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "s3_vpc_endpoint_id" {
  name        = "/localy/prod/network/s3_vpc_endpoint_id"
  description = "Localy Prod - S3 Gateway VPC Endpoint ID for Loki zero-trust bucket policies (Layer 03)"
  type        = "String"
  value       = module.network.s3_vpc_endpoint_id
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "sns_vpc_endpoint_id" {
  name        = "/localy/prod/network/sns_vpc_endpoint_id"
  description = "Localy Prod - SNS Interface VPC Endpoint ID for alarm-pipeline private publish (Layer 03)"
  type        = "String"
  value       = module.network.sns_vpc_endpoint_id
  tags        = module.global.common_tags
}

resource "aws_ssm_parameter" "sts_vpc_endpoint_id" {
  name        = "/localy/prod/network/sts_vpc_endpoint_id"
  description = "Localy Prod - STS Interface VPC Endpoint ID for IRSA AssumeRoleWithWebIdentity (Layer 03)"
  type        = "String"
  value       = module.network.sts_vpc_endpoint_id
  tags        = module.global.common_tags
}

# ========================================================================
# Network — EKS outbound NAT EIP (Slack IP Allowlist 결속용)
# ========================================================================

output "eks_nat_gateway_public_ips" {
  description = "NAT Gateway Elastic IPs for EKS cluster outbound traffic. Register in Slack API IP Allowlist."
  value       = module.network.nat_gateway_public_ips
}

output "eks_nat_gateway_public_ip_cidrs" {
  description = "NAT Gateway EIPs as /32 CIDRs for SaaS allowlist binding."
  value       = module.network.nat_gateway_public_ip_cidrs
}

output "eks_nat_gateway_count" {
  description = "Active NAT Gateway count (verify all IPs are allowlisted when > 1)."
  value       = module.network.nat_gateway_count
}
