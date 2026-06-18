# ========================================================================
# Layer 04 — Provider Configuration (GitOps Bridge)
# ========================================================================
# EKS 인증: 정적 토큰 금지 → exec(aws eks get-token) 동적 세션 (15분 갱신)
# 클러스터 메타: data.aws_ssm_parameter (02-compute 우체통)만 사용
# ========================================================================

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
    helm = {
      source  = "hashicorp/helm"
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
      TerraformLayer = "04-gitops"
    })
  }
}

data "aws_region" "current" {}

# --- Kubernetes Provider (exec 기반 동적 인증) ---
provider "kubernetes" {
  host                   = data.aws_ssm_parameter.eks_endpoint.value
  cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_ca.value)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_ssm_parameter.cluster_name.value,
      "--region", data.aws_region.current.name,
    ]
  }
}

# --- Helm Provider (kubernetes 블록 내 exec 기반 동적 인증) ---
provider "helm" {
  kubernetes {
    host                   = data.aws_ssm_parameter.eks_endpoint.value
    cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_ca.value)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", data.aws_ssm_parameter.cluster_name.value,
        "--region", data.aws_region.current.name,
      ]
    }
  }
}
