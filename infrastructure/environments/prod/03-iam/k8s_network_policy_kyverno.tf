
# ---------------------------------------------------------------------------
# 1. AWS 諛?K8s Data Source ?숈쟻 異붿텧
# ---------------------------------------------------------------------------


data "aws_network_interfaces" "eks_control_plane" {
  filter {
    name   = "description"
    values = ["Amazon EKS ${data.aws_ssm_parameter.cluster_name.value}"]
  }
}

# ?뚯븙??ENI?ㅼ쓽 ?곸꽭 ?뺣낫 議고쉶
data "aws_network_interface" "eks_cp_ips" {
  count = length(data.aws_network_interfaces.eks_control_plane.ids)
  id    = data.aws_network_interfaces.eks_control_plane.ids[count.index]
}

# [SRE ?듯빀] ENI媛 ?꾩튂???쒕툕?????議고쉶 (AWS ?낅뜲?댄듃 ??IP 蹂寃????
data "aws_subnet" "eks_cp_subnets" {
  count = length(data.aws_network_interfaces.eks_control_plane.ids)
  id    = data.aws_network_interface.eks_cp_ips[count.index].subnet_id
}

# [DevSecOps 異붽?] K8s API ?쒕쾭??怨좎젙 ClusterIP ?숈쟻 異붿텧 (?섎뱶肄붾뵫 ?쒓굅)
data "kubernetes_service_v1" "kubernetes_api" {
  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

locals {
  # ENI媛 ?랁븳 ?쒕툕??CIDR 紐⑸줉 異붿텧 諛?以묐났 ?쒓굅
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
    # [諛⑹뼱??1 - INGRESS] Control Plane ?뱁썒 ?섏떊
    # ==========================================
    # ?⑥씪 IP(/32) ?섎뱶肄붾뵫???먰룺 ?꾪뿕???쇳븯怨? 
    # API ?쒕쾭媛 議댁옱?섎뒗 ?듭떖 ?쒕툕???⑥쐞濡쒕쭔 ?뺣??섍쾶 ?덉슜
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

    # Kyverno ?대? 而댄룷?뚰듃 媛??듭떊 ?덉슜
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
    # [諛⑹뼱??2 - EGRESS] API ?쒕쾭 諛?DNS ?듭떊
    # ==========================================
    # 1. K8s API ?쒕쾭 ?듭떊 (?≪쟻 ?대룞 ?먯쿇 李⑤떒 - ?⑥씪 ClusterIP濡?怨좊┰)
    egress {
      to {
        ip_block {
          # "172.20.0.1/32" ?섎뱶肄붾뵫 ???K8s API ?쒕퉬?ㅼ뿉??IP瑜??숈쟻?쇰줈 媛?몄샂
          cidr = "${data.kubernetes_service_v1.kubernetes_api.spec[0].cluster_ip}/32"
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # 2. CoreDNS ?대쫫 ????덉슜
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

  # ?대윭?ㅽ꽣, ?щ쫫李⑦듃媛 紐⑤몢 以鍮꾨맂 ???뺤콉???곸슜?섎룄濡??쒖꽌 蹂댁옣
}
