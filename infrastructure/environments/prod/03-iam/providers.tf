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
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
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
      TerraformLayer = "03-iam"
    })
  }
}

# SSM ?�체??기반 EKS ?�증 ??data.aws_eks_cluster 미사??(plan/apply chicken-and-egg 방�?)
data "aws_region" "current" {}

provider "kubernetes" {
  host                   = data.aws_ssm_parameter.eks_endpoint.value
  cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_ca.value)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_ssm_parameter.cluster_name.value, "--region", data.aws_region.current.name]
  }
}

provider "kubectl" {
  host                   = data.aws_ssm_parameter.eks_endpoint.value
  cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_ca.value)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_ssm_parameter.cluster_name.value, "--region", data.aws_region.current.name]
  }
}
