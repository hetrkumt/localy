terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket = "feifo-prod-tf-state-backend"
    key    = "eks-gitops/prod/l4-bootstrap.tfstate"
    region = "ap-northeast-2"
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_region" "current" {}

# --- L2 EKS SSM Parameter 간접 참조 배관 ---

data "aws_ssm_parameter" "eks_cluster_name" {
  name = local.ssm_paths["eks_cluster_name"]
}

data "aws_ssm_parameter" "eks_cluster_endpoint" {
  name = local.ssm_paths["eks_cluster_endpoint"]
}

data "aws_ssm_parameter" "eks_cluster_ca_data" {
  name = local.ssm_paths["eks_cluster_ca_data"]
}

# --- Providers 설정 (SSM 동적 바인딩) ---

provider "kubernetes" {
  host                   = data.aws_ssm_parameter.eks_cluster_endpoint.value
  cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_cluster_ca_data.value)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.aws_ssm_parameter.eks_cluster_name.value, "--region", data.aws_region.current.name]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_ssm_parameter.eks_cluster_endpoint.value
    cluster_ca_certificate = base64decode(data.aws_ssm_parameter.eks_cluster_ca_data.value)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.aws_ssm_parameter.eks_cluster_name.value, "--region", data.aws_region.current.name]
    }
  }
}

# --------------------------------------------------------
# ArgoCD Helm Release 배포 + 선언적 Root App-of-Apps 매설
# --------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "5.51.6"
  namespace        = "argocd"
  create_namespace = true

  # yamlencode를 통한 복잡한 헬름 값(yaml) 주입
  values = [
    yamlencode({
      configs = {
        cm = {
          "kustomize.buildOptions" = "--enable-helm"
        }
        params = {
          "otlp.address" = ""
        }
      }
    })
  ]
}

# --------------------------------------------------------
# ArgoCD Apps 차트를 통한 선언적 Root App-of-Apps 매설
# --------------------------------------------------------
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "1.6.2" # ArgoCD Apps 차트 버전
  namespace  = "argocd"

  # ArgoCD 핵심 컴포넌트(CRD 포함)가 생성된 이후에 실행되도록 의존성 부여
  depends_on = [helm_release.argocd]

  values = [
    yamlencode({
      applications = [
        {
          name      = "root-app-of-apps"
          namespace = "argocd"
          project   = "default"
          source = {
            repoURL        = "https://github.com/hetrkumt/localy-manifests.git" # 사용자님의 실제 원격 저장소 주소
            targetRevision = "main"                                             # 최초 push한 main 브랜치 적용
            path           = "argocd-apps/overlays/prod"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = [
              "CreateNamespace=true"
            ]
          }
        }
      ]
    })
  ]
}
