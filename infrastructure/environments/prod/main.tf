# ========================================================================
# 📡 EKS GITOPS PLATFORM - MAIN ORCHESTRATION SPECIFICATION
# ========================================================================
# [설명] 본 파일은 우리 인프라의 모든 자원을 총괄하여 발주하는 최상위 설계도입니다.
# 각 단계별 구성 요소들의 유기적인 연결 관계를 정의합니다.
# ========================================================================

# --------------------------------------------------------
# [1단계] 테라폼 백엔드 및 필수 프로바이더 선언
# --------------------------------------------------------
terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket         = "feifo-prod-tf-state-backend"
    key            = "eks-gitops/prod/network.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "feifo-prod-tf-locks"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

# --------------------------------------------------------
# [2단계] AWS Provider 설정
# --------------------------------------------------------
provider "aws" {
  region = "ap-northeast-2"
}

# --------------------------------------------------------
# [3단계] 네트워크(VPC) 모듈 호출
# --------------------------------------------------------
module "network" {
  source = "../../modules/network"

  env_name         = "prod"
  vpc_cidr         = "10.0.0.0/16"
  azs              = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  database_subnets = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

# --------------------------------------------------------
# [4단계] EKS 클러스터 본체 및 시스템 노드 구축 모듈 호출
# --------------------------------------------------------
module "eks" {
  source       = "../../modules/eks"
  cluster_name = "prod-eks"
  vpc_id       = module.network.vpc_id
  admin_ip     = var.admin_ip
  subnet_ids   = module.network.private_subnets
}

# --------------------------------------------------------
# [5단계] Kubernetes / Helm / kubectl Provider (module.eks Output 직접 참조)
# --------------------------------------------------------
# data "aws_eks_cluster"는 클러스터 생성 전 plan/apply 시 'couldn't find resource'를
# 유발하므로 사용하지 않습니다. endpoint/CA는 module.eks output에서 가져옵니다.
# 토큰은 exec(aws eks get-token)으로 갱신하여 정적 토큰 만료를 방지합니다.
# --------------------------------------------------------
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    env = {
      AWS_PROFILE = "terraform-admin"
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      env = {
        AWS_PROFILE = "terraform-admin"
      }
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    env = {
      AWS_PROFILE = "terraform-admin"
    }
  }
}

# --------------------------------------------------------
# [6단계] Karpenter Controller (뇌) 이식 — Helm Release
# --------------------------------------------------------
resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "0.37.0"
  create_namespace = true

  depends_on = [
    module.eks
  ]

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.eks.karpenter_interruption_queue_name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.karpenter_controller_role_arn
  }

  set {
    name  = "nodeSelector.role"
    value = "system"
  }
}
