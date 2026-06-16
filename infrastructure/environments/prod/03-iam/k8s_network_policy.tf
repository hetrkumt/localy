# =============================================================================
# [Frame 2 ??DevSecOps] Zero-Trust NetworkPolicy (Loki Ingress / Fluent Bit Egress)
# =============================================================================
# Loki ?섏떊: monitoring NS + pod label AND 寃곗냽 (?쇰꺼 ?ㅽ뫖??諛⑹뼱)
# Fluent Bit ?≪떊: Loki Gateway :3100 / CoreDNS :53 / K8s API :443 留??덉슜
# Apply ?쒖꽌: loki + fluent_bit 湲곕룞 ??諛⑺솕踰??ы븯
# =============================================================================

locals {
  # main.tf module.network vpc_cidr ? ?숆린??  vpc_cidr = var.vpc_cidr_block
}

# ---------------------------------------------------------------------------
# Loki Ingress Zero-Trust ??observability / Loki Pod ?섏떊 ?듭젣
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

    # Loki ?대? 而댄룷?뚰듃 媛??듭떊 (gateway / write / read / backend)
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
      # 4. Memberlist (UDP - 媛???꾨줈?좎퐳??
      ports {
        port     = "7946"
        protocol = "UDP"
      }
    }

    # Fluent Bit ??Loki push (monitoring NS AND fluent-bit label)
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

    # Grafana ??Loki query (monitoring NS AND grafana label)
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
}

# ---------------------------------------------------------------------------
# Fluent Bit Egress Zero-Trust ??monitoring / Fluent Bit Pod ?≪떊 ?듭젣
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

    # CoreDNS (Service FQDN ?댁꽍)
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
}

# =============================================================================
# [Frame 2 ??DevSecOps] Alertmanager Zero-Trust NetworkPolicy (Ingress + Egress)
# =============================================================================

data "aws_network_interfaces" "alertmanager_sns_vpc_endpoint" {
  filter {
    name   = "vpc-endpoint-id"
    values = [data.aws_ssm_parameter.sns_vpc_endpoint_id.value]
  }
}

data "aws_network_interfaces" "alertmanager_sts_vpc_endpoint" {
  filter {
    name   = "vpc-endpoint-id"
    values = [data.aws_ssm_parameter.sts_vpc_endpoint_id.value]
  }
}

data "aws_network_interface" "alertmanager_sns_vpc_endpoint" {
  count = length(data.aws_network_interfaces.alertmanager_sns_vpc_endpoint.ids)
  id    = data.aws_network_interfaces.alertmanager_sns_vpc_endpoint.ids[count.index]
}

data "aws_network_interface" "alertmanager_sts_vpc_endpoint" {
  count = length(data.aws_network_interfaces.alertmanager_sts_vpc_endpoint.ids)
  id    = data.aws_network_interfaces.alertmanager_sts_vpc_endpoint.ids[count.index]
}

locals {
  alertmanager_aws_vpce_cidrs = distinct(concat(
    [for eni in data.aws_network_interface.alertmanager_sns_vpc_endpoint : "${eni.private_ip}/32"],
    [for eni in data.aws_network_interface.alertmanager_sts_vpc_endpoint : "${eni.private_ip}/32"],
  ))
}

resource "kubernetes_network_policy_v1" "alertmanager_zero_trust" {
  metadata {
    name      = "alertmanager-zero-trust"
    namespace = "monitoring"
    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "network-policy"
      "managed-by"                  = "terraform"
    }
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "alertmanager"
      }
    }

    policy_types = ["Ingress", "Egress"]

    # -----------------------------------------------------------------------
    # [Ingress 1] Prometheus ??Alertmanager (:9093)
    # -----------------------------------------------------------------------
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
            "app.kubernetes.io/name"     = "prometheus"
            "app.kubernetes.io/instance" = "kube-prometheus-stack"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9093"
      }
    }

    # -----------------------------------------------------------------------
    # [Ingress 2] Loki Ruler ??Alertmanager (:9093)
    # -----------------------------------------------------------------------
    ingress {
      from {
        namespace_selector {
          match_expressions {
            key      = "kubernetes.io/metadata.name"
            operator = "In"
            values   = ["observability"]
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "loki"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9093"
      }
    }

    # -----------------------------------------------------------------------
    # [Ingress & Egress 3] Alertmanager HA 硫ㅻ쾭由ъ뒪??(TCP/UDP 9094)
    # -----------------------------------------------------------------------
    ingress {
      from {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "alertmanager"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9094"
      }
      ports {
        protocol = "UDP"
        port     = "9094"
      }
    }

    egress {
      to {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "alertmanager"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "9094"
      }
      ports {
        protocol = "UDP"
        port     = "9094"
      }
    }

    # -----------------------------------------------------------------------
    # [Egress 1] CoreDNS ?대쫫 ???(UDP/TCP 53)
    # -----------------------------------------------------------------------
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

    # -----------------------------------------------------------------------
    # [Egress 2] SNS/STS Interface VPC Endpoint ENIs only (HTTPS 443)
    # -----------------------------------------------------------------------
    egress {
      dynamic "to" {
        for_each = local.alertmanager_aws_vpce_cidrs
        content {
          ip_block {
            cidr = to.value
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
