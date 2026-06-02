# =============================================================================
# [Frame 2 — DevSecOps] Zero-Trust NetworkPolicy (Loki Ingress / Fluent Bit Egress)
# =============================================================================
# Loki 수신: monitoring NS + pod label AND 결속 (라벨 스푸핑 방어)
# Fluent Bit 송신: Loki Gateway :3100 / CoreDNS :53 / K8s API :443 만 허용
# Apply 순서: loki + fluent_bit 기동 후 방화벽 투하
# =============================================================================

locals {
  # main.tf module.network vpc_cidr 와 동기화
  vpc_cidr = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Loki Ingress Zero-Trust — observability / Loki Pod 수신 통제
# ---------------------------------------------------------------------------
resource "kubernetes_network_policy_v1" "loki_ingress_zero_trust" {
  metadata {
    name      = "loki-ingress-zero-trust"
    namespace = "observability"

    labels = {
      "app.kubernetes.io/name"      = "loki"
      "app.kubernetes.io/component" = "network-policy"
      "managed-by"                  = "terraform"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "loki"
      }
    }

    policy_types = ["Ingress"]

    # Loki 내부 컴포넌트 간 통신 (gateway / write / read / backend)
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "loki"
          }
        }
      }

      ports {
        port     = "3100"
        protocol = "TCP"
      }
      # 2. gRPC
      ports {
        port     = "9095"
        protocol = "TCP"
      }
      # 3. Memberlist (TCP)
      ports {
        port     = "7946"
        protocol = "TCP"
      }
      # 4. Memberlist (UDP - 가십 프로토콜용)
      ports {
        port     = "7946"
        protocol = "UDP"
      }
    }

    # Fluent Bit → Loki push (monitoring NS AND fluent-bit label)
    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["monitoring"]
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "fluent-bit"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "3100"
      }
    }

    # Grafana → Loki query (monitoring NS AND grafana label)
    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["monitoring"]
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "grafana"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "3100"
      }
    }
  }

  depends_on = [
    helm_release.loki,
    helm_release.fluent_bit,
  ]
}

# ---------------------------------------------------------------------------
# Fluent Bit Egress Zero-Trust — monitoring / Fluent Bit Pod 송신 통제
# ---------------------------------------------------------------------------
resource "kubernetes_network_policy_v1" "fluent_bit_egress_zero_trust" {
  metadata {
    name      = "fluent-bit-egress-zero-trust"
    namespace = "monitoring"

    labels = {
      "app.kubernetes.io/name"      = "fluent-bit"
      "app.kubernetes.io/component" = "network-policy"
      "managed-by"                  = "terraform"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "fluent-bit"
      }
    }

    policy_types = ["Egress"]

    # CoreDNS (Service FQDN 해석)
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

    # Loki Gateway push (observability NS AND gateway component)
    egress {
      to {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["observability"]
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "loki"
            "app.kubernetes.io/component" = "gateway"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "3100"
      }
    }
  }
  depends_on = [
    helm_release.loki,
    helm_release.fluent_bit,
  ]
}
