terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket         = "feifo-prod-tf-state-backend"
    key            = "eks-gitops/prod/l1-network.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "feifo-prod-tf-locks"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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


# --- SSM Parameter 경로 중앙 변수화 (Prefix Interpolation) ---
locals {
  ssm_prefix = "/localy/${var.env_name}"

  ssm_paths = {
    vpc_id             = "${local.ssm_prefix}/network/vpc_id"
    private_subnets    = "${local.ssm_prefix}/network/private_subnets"
    database_subnets   = "${local.ssm_prefix}/network/database_subnets"
    pod_subnets        = "${local.ssm_prefix}/network/pod_subnets"
    s3_vpc_endpoint_id = "${local.ssm_prefix}/network/s3_vpc_endpoint_id"
    shared_alb_sg_id   = "${local.ssm_prefix}/network/shared_alb_sg_id"

    # Target Groups
    eks_tg_arn     = "${local.ssm_prefix}/network/target_groups/eks"
    user_tg_arn    = "${local.ssm_prefix}/network/target_groups/user"
    cart_tg_arn    = "${local.ssm_prefix}/network/target_groups/cart"
    payment_tg_arn = "${local.ssm_prefix}/network/target_groups/payment"
    store_tg_arn   = "${local.ssm_prefix}/network/target_groups/store"
  }
}

module "network" {
  source = "../../../modules/network"

  env_name         = var.env_name
  vpc_cidr         = "10.0.0.0/16"
  secondary_cidr   = "100.64.0.0/16"
  azs              = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# [신규 추가] ALB 라우팅 규칙 (Listener Rules)
# -----------------------------------------------------------------------------

resource "aws_lb_listener_rule" "edge_routing" {
  listener_arn = module.network.http_listener_arn
  priority     = 90

  action {
    type             = "forward"
    target_group_arn = module.network.target_groups_map["eks"]
  }

  condition {
    path_pattern {
      values = ["/api/*", "/images/*", "/login/*", "/oauth2/*"]
    }
  }
}


