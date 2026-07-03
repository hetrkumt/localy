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
