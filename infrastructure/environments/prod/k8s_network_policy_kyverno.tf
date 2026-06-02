# =============================================================================
# [3차 워게임 — DevSecOps] Kyverno Admission Webhook Zero-Trust NetworkPolicy
# =============================================================================
# EKS Control Plane → validating webhook(9443) Ingress / API·CoreDNS Egress만 허용
# ingress CIDR: 기본 VPC CIDR(data.aws_vpc) — kyverno_admission_webhook_ingress_cidrs 로 좁힐 수 있음
# Apply 순서: Kyverno Helm 기동 후 (helm_kyverno.tf 연동 시 depends_on 추가)
# =============================================================================

variable "kyverno_namespace" {
  description = "Kyverno Helm release namespace"
  type        = string
  default     = "kyverno"
}

variable "kyverno_admission_webhook_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach Kyverno admission webhook (EKS Control Plane ENI 대역).
    비어 있으면 EKS VPC CIDR(module.network)을 사용합니다.
    운영에서는 AWS 콘솔/EKS ENI 기준으로 CP 전용 CIDR만 남기도록 좁히세요.
  EOT
  type        = list(string)
  default     = []
}

variable "kyverno_admission_webhook_port" {
  description = "Kyverno admission Service targetPort (차트 기본 9443 — kubectl get svc -n kyverno 로 확인)"
  type        = number
  default     = 9443
}

data "aws_vpc" "eks" {
  id = module.network.vpc_id
}

locals {
  kyverno_admission_ingress_cidrs = length(var.kyverno_admission_webhook_ingress_cidrs) > 0 ? var.kyverno_admission_webhook_ingress_cidrs : [data.aws_vpc.eks.cidr_block]
  kyverno_api_egress_cidrs        = local.kyverno_admission_ingress_cidrs
}

# ---------------------------------------------------------------------------
# Kyverno Admission Controller — Control Plane Ingress + 최소 Egress
# ---------------------------------------------------------------------------
resource "kubernetes_network_policy_v1" "kyverno_admission_ingress_zero_trust" {
  metadata {
    name      = "kyverno-admission-ingress-zero-trust"
    namespace = var.kyverno_namespace

    labels = {
      "app.kubernetes.io/name"      = "kyverno"
      "app.kubernetes.io/component" = "network-policy"
      "managed-by"                  = "terraform"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = "admission-controller"
      }
    }

    policy_types = ["Ingress", "Egress"]

    dynamic "ingress" {
      for_each = local.kyverno_admission_ingress_cidrs
      content {
        from {
          ip_block {
            cidr = ingress.value
          }
        }

        ports {
          protocol = "TCP"
          port     = tostring(var.kyverno_admission_webhook_port)
        }
      }
    }

    # Kyverno 내부 컴포넌트 → admission-controller (reports / background 등)
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/part-of" = "kyverno"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.kyverno_admission_webhook_port)
      }
    }

    dynamic "egress" {
      for_each = local.kyverno_api_egress_cidrs
      content {
        to {
          ip_block {
            cidr = egress.value
          }
        }

        ports {
          protocol = "TCP"
          port     = "443"
        }
      }
    }

    # CoreDNS (Service FQDN / cluster DNS 해석)
    egress {
      to {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["kube-system"]
          }
        }
        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }

  depends_on = [
    module.eks,
  ]
}
