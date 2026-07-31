terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket         = "feifo-prod-tf-state-backend"
    key            = "eks-gitops/prod/l4-bootstrap.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "feifo-prod-tf-locks"
    encrypt        = true
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
# ArgoCD Helm Release — Phase 8: Multi-Source SSOT (no enable-helm)
# --------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "5.51.6"
  namespace        = "argocd"
  create_namespace = true

  values = [
    yamlencode({
      configs = {
        params = {
          "otlp.address" = ""
        }
      }
    })
  ]
}

# --------------------------------------------------------
# Gate 8A — Retarget Root App-of-Apps to gitops/overlays/prod
# prune=false / selfHeal=true (Gate 8B prune:true after soak)
# Physical archive of argocd-apps/ bootstrap/ deferred to Go-Live (8C)
# --------------------------------------------------------
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "1.6.2"
  namespace  = "argocd"

  depends_on = [helm_release.argocd]

  values = [
    yamlencode({
      applications = [
        {
          name      = "root-app-of-apps"
          namespace = "argocd"
          project   = "default"
          source = {
            repoURL        = "https://github.com/hetrkumt/localy-manifests.git"
            targetRevision = "main"
            path           = "gitops/overlays/prod"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = false
              selfHeal = true
            }
            syncOptions = [
              "CreateNamespace=true",
              "ServerSideApply=true",
              "Delete=false",
              "Prune=false"
            ]
          }
        }
      ]
    })
  ]
}