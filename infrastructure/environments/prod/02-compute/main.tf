# ========================================================================
# SSM Import — 1계층 Network 우체통에서 VPC/Subnet 수신
# ========================================================================

data "aws_ssm_parameter" "vpc_id" {
  name = "/localy/prod/network/vpc_id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/localy/prod/network/private_subnet_ids"
}

# --------------------------------------------------------
# Terraform 실행 환경 공인 IP (EKS API public_access_cidrs용)
# --------------------------------------------------------
data "http" "myip" {
  url = "https://checkip.amazonaws.com"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch Terraform runner public IP (status ${self.status_code})"
    }
  }
}

locals {
  terraform_runner_public_cidr = "${chomp(data.http.myip.response_body)}/32"
  eks_public_access_cidrs = distinct(compact(concat(
    [local.terraform_runner_public_cidr],
    var.admin_ip != "" ? [var.admin_ip] : [],
    var.allow_global_cluster_api_access ? ["0.0.0.0/0"] : [],
  )))
}

# --------------------------------------------------------
# EKS 클러스터 본체 및 시스템 노드 구축
# --------------------------------------------------------
module "eks" {
  source       = "../../../modules/eks"
  cluster_name = module.global.cluster_name
  vpc_id       = data.aws_ssm_parameter.vpc_id.value
  admin_ip     = var.admin_ip
  subnet_ids   = jsondecode(data.aws_ssm_parameter.private_subnet_ids.value)

  cluster_endpoint_public_access = true
  public_access_cidrs            = local.eks_public_access_cidrs

  cluster_security_group_additional_rules = merge(
    length(setsubtract(toset(local.eks_public_access_cidrs), toset(var.admin_ip != "" ? [var.admin_ip] : []))) > 0 ? {
      terraform_runner_https = {
        type        = "ingress"
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = tolist(setsubtract(toset(local.eks_public_access_cidrs), toset(var.admin_ip != "" ? [var.admin_ip] : [])))
        description = "Allow HTTPS to cluster SG from Terraform runner / allowed CIDRs"
      }
    } : {}
  )
}
