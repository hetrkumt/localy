terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket         = "feifo-prod-tf-state-backend"
    key            = "eks-gitops/prod/l1-network.tfstate"
    region         = "ap-northeast-2"
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
    s3_vpc_endpoint_id = "${local.ssm_prefix}/network/s3_vpc_endpoint_id"
  }
}

module "network" {
  source = "../../../modules/network"

  env_name         = var.env_name
  vpc_cidr         = "10.0.0.0/16"
  azs              = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
