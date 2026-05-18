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
  }
}

# --------------------------------------------------------
# [2단계] AWS Provider 설정
# --------------------------------------------------------
provider "aws" {
  region = "ap-northeast-2"
}

# --------------------------------------------------------
# [3단계] EKS 클러스터 인증 정보 동적 획득 (Dynamic Exec)
# --------------------------------------------------------
# [설명] 15분짜리 정적 토큰 만료 장애를 방지하기 위해 실시간 인증 체계를 가동합니다.
# 자식 프로세스(aws) 실행 시 환경 변수 유실로 인한 Unauthorized 401 에러를 방지하기 위해,
# env 블록을 통해 'terraform-admin' 프로필을 강제적으로 지정(Explicit Injection)합니다.
# [주의] 데이터 소스에 depends_on을 사용하면 plan 단계에서 인증 정보가 누락되어 
# 'Kubernetes cluster unreachable' 에러가 납니다. 이미 클러스터가 구축되어 있으므로 
# depends_on 체인을 완전히 끊고(Decoupling) 직접 조회합니다.
# --------------------------------------------------------
data "aws_eks_cluster" "cluster" {
  name = "prod-eks"
}

data "aws_eks_cluster_auth" "cluster" {
  name = "prod-eks"
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", "prod-eks"]
      command     = "aws"
      env = {
        AWS_PROFILE = "terraform-admin"
      }
    }
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", "prod-eks"]
    command     = "aws"
    env = {
      AWS_PROFILE = "terraform-admin"
    }
  }
  load_config_file       = false
}

# --------------------------------------------------------
# [4단계] 네트워크(VPC) 모듈 호출
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
# [5단계] EKS 클러스터 본체 및 시스템 노드 구축 모듈 호출
# --------------------------------------------------------
module "eks" {
  source       = "../../modules/eks"
  cluster_name = "prod-eks"
  vpc_id       = module.network.vpc_id
  admin_ip     = var.admin_ip
  subnet_ids   = module.network.private_subnets
}

# --------------------------------------------------------
# [6단계] Karpenter Controller (뇌) 이식 - Helm Release
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
