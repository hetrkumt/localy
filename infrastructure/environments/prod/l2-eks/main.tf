terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket         = "feifo-prod-tf-state-backend"
    key            = "eks-gitops/prod/l2-eks.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "feifo-prod-tf-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# L1 네트워크 정보를 SSM Parameter Store로부터 간접 참조 취득
data "aws_ssm_parameter" "vpc_id" {
  name = local.ssm_paths["vpc_id"]
}

data "aws_ssm_parameter" "private_subnets" {
  name = local.ssm_paths["private_subnets"]
}

# --------------------------------------------------------
# 로컬 Terraform 실행 환경 공인 IP (EKS API public_access_cidrs용)
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
# EKS 클러스터 본체 및 시스템 노드 구축 모듈 호출
# --------------------------------------------------------
module "eks" {
  source       = "../../../modules/eks"
  cluster_name = "prod-eks"
  vpc_id       = data.aws_ssm_parameter.vpc_id.value
  admin_ip     = var.admin_ip
  subnet_ids   = split(",", data.aws_ssm_parameter.private_subnets.value)

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

# --------------------------------------------------------
# Kubernetes Provider (module.eks Output 직접 참조)
# --------------------------------------------------------
data "aws_region" "current" {}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", data.aws_region.current.name]
  }
}

# --------------------------------------------------------
# [무결성 핫픽스] Shared ALB -> EKS Node SG 통신 허용 체이닝
# --------------------------------------------------------
data "aws_security_group" "shared_alb" {
  name = "prod-shared-alb-sg"
}

resource "aws_security_group_rule" "node_ingress_shared_alb" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = data.aws_security_group.shared_alb.id
  security_group_id        = module.eks.node_security_group_id
  description              = "Allow all TCP traffic from Shared ALB to EKS Nodes for TargetGroupBinding health checks and routing"
}
