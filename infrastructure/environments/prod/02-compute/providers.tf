terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

module "global" {
  source = "../../../modules/global_config"
}

provider "aws" {
  region = module.global.region

  default_tags {
    tags = merge(module.global.common_tags, {
      TerraformLayer = "02-compute"
    })
  }
}

# data "aws_eks_cluster"는 클러스터 생성 전 plan/apply 시 'couldn't find resource'를
# 유발하므로 사용하지 않습니다. endpoint/CA는 module.eks output에서 가져옵니다.
# 토큰은 exec(aws eks get-token)으로 갱신하여 정적 토큰 만료를 방지합니다.
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

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", data.aws_region.current.name]
  }
}
