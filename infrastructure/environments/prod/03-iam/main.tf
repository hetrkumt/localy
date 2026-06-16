# ========================================================================
# SSM Import Hub ??1/2ê³„ì¸µ ?°ì²´???µí•© ?˜ì‹  (ì´?13ê°?
# ========================================================================

# --- Layer 01 Network (5) ---

data "aws_ssm_parameter" "vpc_id" {
  name = "/localy/prod/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/localy/prod/network/private_subnet_ids"
}

data "aws_ssm_parameter" "s3_vpc_endpoint_id" {
  name = "/localy/prod/network/s3_vpc_endpoint_id"
}

data "aws_ssm_parameter" "sns_vpc_endpoint_id" {
  name = "/localy/prod/network/sns_vpc_endpoint_id"
}

data "aws_ssm_parameter" "sts_vpc_endpoint_id" {
  name = "/localy/prod/network/sts_vpc_endpoint_id"
}

# --- Layer 02 Compute (8) ---

data "aws_ssm_parameter" "cluster_name" {
  name = "/localy/prod/compute/cluster_name"
}

data "aws_ssm_parameter" "eks_endpoint" {
  name = "/localy/prod/compute/eks_endpoint"
}

data "aws_ssm_parameter" "eks_ca" {
  name = "/localy/prod/compute/eks_ca"
}

data "aws_ssm_parameter" "oidc_provider_arn" {
  name = "/localy/prod/compute/oidc_provider_arn"
}

data "aws_ssm_parameter" "oidc_issuer_url" {
  name = "/localy/prod/compute/oidc_issuer_url"
}

data "aws_ssm_parameter" "kms_key_arn" {
  name = "/localy/prod/compute/kms_key_arn"
}

data "aws_ssm_parameter" "ebs_csi_role_name" {
  name = "/localy/prod/compute/ebs_csi_role_name"
}

data "aws_ssm_parameter" "ebs_csi_role_arn" {
  name = "/localy/prod/compute/ebs_csi_role_arn"
}
