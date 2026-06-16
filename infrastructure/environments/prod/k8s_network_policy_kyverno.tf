
variable "kyverno_namespace" {
  description = "Kyverno Helm release namespace"
  type        = string
  default     = "kyverno"
}

variable "kyverno_admission_webhook_port" {
  description = "Kyverno admission Service targetPort"
  type        = number
  default     = 9443
}

# ---------------------------------------------------------------------------
# 1. AWS 및 K8s Data Source 동적 추출
# ---------------------------------------------------------------------------


data "aws_network_interfaces" "eks_control_plane" {
  filter {
    name   = "description"
    values = ["Amazon EKS ${module.eks.cluster_name}"]
  }
}

# 파악된 ENI들의 상세 정보 조회
data "aws_network_interface" "eks_cp_ips" {
  count = length(data.aws_network_interfaces.eks_control_plane.ids)
  id    = data.aws_network_interfaces.eks_control_plane.ids[count.index]
}

# [SRE 융합] ENI가 위치한 서브넷 대역 조회 (AWS 업데이트 시 IP 변경 대응)
data "aws_subnet" "eks_cp_subnets" {
  count = length(data.aws_network_interfaces.eks_control_plane.ids)
  id    = data.aws_network_interface.eks_cp_ips[count.index].subnet_id
}

# [DevSecOps 추가] K8s API 서버의 고정 ClusterIP 동적 추출 (하드코딩 제거)
data "kubernetes_service_v1" "kubernetes_api" {
  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
  
  depends_on = [module.eks]
}

locals {
  # ENI가 속한 서브넷 CIDR 목록 추출 및 중복 제거
  eks_cp_subnet_cidrs = distinct([for subnet in data.aws_subnet.eks_cp_subnets : subnet.cidr_block])
}
# ---------------------------------------------------------------------------
# 2. Kyverno Admission Controller NetworkPolicy
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

    # ==========================================
    # [방어선 1 - INGRESS] Control Plane 웹훅 수신
    # ==========================================
    # 단일 IP(/32) 하드코딩의 자폭 위험을 피하고, 
    # API 서버가 존재하는 핵심 서브넷 단위로만 정밀하게 허용
    dynamic "ingress" {
      for_each = local.eks_cp_subnet_cidrs
      content {
        from {
          ip_block {
            cidr = ingress.value
          }
        }
        ports {
          protocol = "TCP"
          port     = "9443"
        }
      }
    }

    # Kyverno 내부 컴포넌트 간 통신 허용
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

    # ==========================================
    # [방어선 2 - EGRESS] API 서버 및 DNS 통신
    # ==========================================
    # 1. K8s API 서버 통신 (횡적 이동 원천 차단 - 단일 ClusterIP로 고립)
    egress {
      to {
        ip_block {
          # "172.20.0.1/32" 하드코딩 대신 K8s API 서비스에서 IP를 동적으로 가져옴
          cidr = "${data.kubernetes_service_v1.kubernetes_api.spec[0].cluster_ip}/32"
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # 2. CoreDNS 이름 풀이 허용
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

  # 클러스터, 헬름차트가 모두 준비된 후 정책이 적용되도록 순서 보장
  depends_on = [
    module.eks,
  ]
}