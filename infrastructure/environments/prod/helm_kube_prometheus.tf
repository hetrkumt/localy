# =============================================================================
# [Frame 2 - Step 2] 관제탑 코어 기동 (Prometheus & Grafana)
# Part 1: 관제탑 뼈대 및 보안 통제 (Base & Security)
# =============================================================================

# -----------------------------------------------------------------------------
# Task 1: Grafana Admin Password 동적 생성
# (※ 주의: tfstate 평문 노출 부채 발생. Frame 3에서 Secrets Manager로 이관 예정)
# -----------------------------------------------------------------------------
resource "random_password" "grafana_admin" {
  length           = 16
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"
}

locals {
  alertmanager_cluster_tls_secret_name    = "alertmanager-cluster-tls"
  alertmanager_cluster_tls_configmap_name = "alertmanager-cluster-tls-config"
  alertmanager_templates_configmap_name   = "alertmanager-templates"
}

# -----------------------------------------------------------------------------
# [Phase 1] Alertmanager gossip mTLS — cert-manager Issuer / Certificate
# Secret 소유권: cert-manager 단독 (Terraform random_password 폐기)
# -----------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

resource "kubernetes_manifest" "alertmanager_cluster_ca_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "alertmanager-cluster-ca"
      namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    }
    spec = {
      selfSigned = {}
    }
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace_v1.monitoring,
    helm_release.kube_prometheus_stack
  ]
}

resource "kubernetes_manifest" "alertmanager_cluster_tls_certificate" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.alertmanager_cluster_tls_secret_name
      namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    }
    spec = {
      secretName  = local.alertmanager_cluster_tls_secret_name
      duration    = "8760h"
      renewBefore = "720h"
      issuerRef = {
        name = kubernetes_manifest.alertmanager_cluster_ca_issuer.manifest.metadata.name
        kind = "Issuer"
      }
      commonName = "alertmanager-cluster"
      dnsNames = [
        "kube-prometheus-stack-alertmanager",
        "kube-prometheus-stack-alertmanager.monitoring",
        "kube-prometheus-stack-alertmanager.monitoring.svc",
        "kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local",

        "alertmanager-operated",
        "alertmanager-operated.monitoring",
        "alertmanager-operated.monitoring.svc",
        "alertmanager-operated.monitoring.svc.cluster.local",
        "alertmanager-kube-prometheus-stack-alertmanager-0.alertmanager-operated",
        "alertmanager-kube-prometheus-stack-alertmanager-1.alertmanager-operated"
      ]
      ipAddresses = ["127.0.0.1"]
    }
  }

  depends_on = [
    #kubernetes_manifest.alertmanager_cluster_ca_issuer,
  ]
}

resource "kubernetes_config_map_v1" "alertmanager_cluster_tls_config" {
  metadata {
    name      = local.alertmanager_cluster_tls_configmap_name
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "cluster-tls-config"
      "managed-by"                  = "terraform"
    }
  }

  data = {
    "tls-config.yaml" = <<-EOF
      tls_server_config:
        cert_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/tls.crt
        key_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/tls.key
        client_auth_type: RequireAndVerifyClientCert
        client_ca_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/ca.crt
      tls_client_config:
        cert_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/tls.crt
        key_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/tls.key
        ca_file: /etc/alertmanager/secrets/${local.alertmanager_cluster_tls_secret_name}/ca.crt
    EOF
  }

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}

# -----------------------------------------------------------------------------
# Task 2~4: 방어적 SRE 튜닝이 결속된 관제탑 본체 투하
# -----------------------------------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.2.2" # 안정성이 검증된 최신 Stable 버전
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 600

  # [SRE 튜닝] EBS CSI 기동 후, ALB Controller Webhook이 준비된 뒤 관제탑(Grafana Ingress 등)을 배포합니다.
  depends_on = [
    aws_eks_addon.ebs_csi,
    helm_release.aws_load_balancer_controller,
    aws_iam_role.alarm_pipeline_sns,
    helm_release.cert_manager,
    #kubernetes_manifest.alertmanager_cluster_tls_certificate,
    #kubernetes_config_map_v1.alertmanager_cluster_tls_config,
    kubernetes_config_map_v1.alertmanager_templates,
  ]


  values = [
    yamlencode({
      # -----------------------------------------------------------------------
      # [Part 1] Grafana 보안 통제 튜닝
      # -----------------------------------------------------------------------
      grafana = {
        adminPassword = random_password.grafana_admin.result

        serviceAccount = {
          create = true
          annotations = {
            "eks.amazonaws.com/role-arn" = module.eks.grafana_irsa_arn
          }
        }
        additionalDataSources = [
          {
            name   = "Prometheus TF"
            type   = "prometheus"
            uid    = "Prometheus_TF"
            url    = "http://kube-prometheus-stack-prometheus.monitoring:9090"
            access = "proxy"
          },
          {
            name   = "Prometheus LBC"
            type   = "prometheus"
            uid    = "Prometheus_LBC"
            url    = "http://kube-prometheus-stack-prometheus.monitoring:9090"
            access = "proxy"
          },
          {
            name   = "CloudWatch"
            type   = "cloudwatch"
            uid    = "CloudWatch_TF"
            access = "proxy"
            jsonData = {
              authType      = "default"        # EKS 워커 노드에 부여된 IAM 권한을 그대로 상속받음
              defaultRegion = "ap-northeast-2" # 서울 리전 타겟팅
            }
          },
          {
            name   = "Loki"
            type   = "loki"
            uid    = "Loki_TF"
            url    = "http://loki-gateway.observability.svc.cluster.local:3100"
            access = "proxy"
            jsonData = {
              httpHeaderName1 = "X-Scope-OrgID"
            }
            secureJsonData = {
              httpHeaderValue1 = "default"
            }
          },
          {
            name   = "Loki SecOps VIP"
            type   = "loki"
            uid    = "Loki_SecOps_VIP"
            url    = "http://loki-gateway.observability.svc.cluster.local:3100"
            access = "proxy"
            jsonData = {
              httpHeaderName1 = "X-Scope-OrgID"
            }
            secureJsonData = {
              httpHeaderValue1 = "secops-admin"
            }
          }
        ]


        sidecar = {
          dashboards = {
            enabled    = true
            label      = "grafana_dashboard"
            labelValue = "1"
          }
        }

        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations = {
            # 1. 퍼블릭 망 노출
            "alb.ingress.kubernetes.io/scheme" = "internet-facing"
            # 2. 공유 ALB 그룹 결속 (비용 최적화)
            "alb.ingress.kubernetes.io/group.name"   = "prod-ingress-group"
            "alb.ingress.kubernetes.io/target-type"  = "ip"
            "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTPS\":443}]"

            # 3. acm.tf 리소스를 직접 바라보도록 'data.' 제거
            "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate.prod_cert.arn

            # 4. waf.tf의 실제 리소스 이름인 'ingress_waf'로 명칭 교정
            "alb.ingress.kubernetes.io/wafv2-acl-arn" = aws_wafv2_web_acl.ingress_waf.arn
          }
          hosts = [
            "grafana.feifo.click" # 접속할 관제탑 URL
          ]
          paths = ["/*"]
        }
      }

      # -----------------------------------------------------------------------
      # [Part 2 & 3] Prometheus SRE 튜닝 (Storage, AZ Pinning, OOM 방어)
      # -----------------------------------------------------------------------
      prometheus = {
        prometheusSpec = {
          # [Part 2] 데이터 보존 주기 14일
          retention = "14d"

          # [Part 2] AZ Pinning 및 온디맨드 스케줄링 강제 (Karpenter 족쇄)
          nodeSelector = {
            "topology.kubernetes.io/zone" = "ap-northeast-2a"
            "karpenter.sh/capacity-type"  = "on-demand"
          }

          # [Part 2] EBS CSI 기반 50Gi gp3 영구 스토리지 프로비저닝
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
              }
            }
          }

          # -------------------------------------------------------------------
          # [Part 3] OOMKilled 방어 및 리소스 격리 (Graviton 8GB 노드 기준)
          # -------------------------------------------------------------------
          resources = {
            requests = {
              cpu    = "500m"
              memory = "2Gi" # 최소 보장 메모리
            }
            limits = {
              cpu    = "1000m"
              memory = "4Gi" # 최대 허용 메모리 (초과 시 해당 파드만 즉시 사살)
            }
          }
        }
      }

      # -----------------------------------------------------------------------
      # [Phase 3] Alertmanager Multi-AZ HA — 2-AZ 분산 + On-Demand + PDB
      # [Phase 4] Alertmanager DevSecOps — SA 거세 + IRSA + 컨테이너 경화
      # [Phase 1] FinOps gossip 튜닝 + mTLS (cert-manager B-1)
      # -----------------------------------------------------------------------
      alertmanager = {
        serviceAccount = {
          create = true
          name   = local.alarm_pipeline_alertmanager_sa_name
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.alarm_pipeline_sns.arn
          }
          automountServiceAccountToken = false
        }

        podDisruptionBudget = {
          enabled      = true
          minAvailable = 1
        }

        # [Phase 4] Template glob — chart default config 보존 + chatops-top3.tmpl mount path
        config = {
          global = {
            resolve_timeout = "5m"
          }
          inhibit_rules = [
            {
              # 백슬래시(\)를 사용하여 큰따옴표를 문자열 안에 포함시킵니다.
              source_matchers = ["severity=\"critical\""]
              target_matchers = ["severity=~\"warning|info\""]
              equal           = ["namespace", "alertname"]
            },
            {
              source_matchers = ["severity=\"warning\""]
              target_matchers = ["severity=\"info\""]
              equal           = ["namespace", "alertname"]
            },
            {
              source_matchers = ["alertname=\"InfoInhibitor\""]
              target_matchers = ["severity=\"info\""]
              equal           = ["namespace"]
            },
            {
              target_matchers = ["alertname=\"InfoInhibitor\""]
            },
          ]
          route = {
            group_by        = ["namespace"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "12h"
            receiver        = "null"
            routes = [
              {
                receiver = "null"
                # 여기 matchers에도 동일하게 적용합니다.
                matchers = ["alertname=\"Watchdog\""]
              },
            ]
          }
          receivers = [
            { name = "null" },
          ]
          templates = [
            "/etc/alertmanager/config/*.tmpl",
            "/etc/alertmanager/configmaps/alertmanager-templates/*.tmpl",
          ]
        }

        alertmanagerSpec = {
          replicas = 2

          nodeSelector = {
            "karpenter.sh/capacity-type" = "on-demand"
          }

          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      "app.kubernetes.io/name"     = "alertmanager"
                      "app.kubernetes.io/instance" = "kube-prometheus-stack-alertmanager"
                    }
                  }
                  topologyKey = "topology.kubernetes.io/zone"
                },
              ]
            }
          }

          resources = {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "512Mi"
            }
          }

          automountServiceAccountToken = false

          secrets = [
            local.alertmanager_cluster_tls_secret_name,
          ]

          configMaps = [
            local.alertmanager_cluster_tls_configmap_name,
            local.alertmanager_templates_configmap_name,
          ]

          additionalArgs = [
            {
              name  = "cluster.gossip-interval"
              value = "2s"
            },
            {
              name  = "cluster.pushpull-interval"
              value = "3m"
            },
            {
              name  = "cluster.tls-config"
              value = "/etc/alertmanager/configmaps/${local.alertmanager_cluster_tls_configmap_name}/tls-config.yaml"
            }
          ]

          # [Phase 3] AlertmanagerConfig CRD discovery — alarm-pipeline routing/inhibition
          alertmanagerConfigSelector = {
            matchLabels = {
              alertmanagerconfig = "alarm-pipeline"
            }
          }

          alertmanagerConfigNamespaceSelector = {
            matchLabels = {
              "kubernetes.io/metadata.name" = "monitoring"
            }
          }

          # [Phase 3 — 권고] cross-namespace alert matching (Phase 2 tier rules)
          alertmanagerConfigMatcherStrategy = {
            type = "None"
          }

          securityContext = {
            runAsNonRoot = true
            runAsUser    = 1000
            runAsGroup   = 2000
            fsGroup      = 2000
            seccompProfile = {
              type = "RuntimeDefault"
            }
          }

          containers = [
            {
              name = "alertmanager"
              securityContext = {
                readOnlyRootFilesystem   = true
                allowPrivilegeEscalation = false
                privileged               = false
                capabilities = {
                  drop = ["ALL"]
                }
                seccompProfile = {
                  type = "RuntimeDefault"
                }
              }
            },
          ]
        }
      }
    })
  ]
}

# -----------------------------------------------------------------------------
# Output: 초기 접속용 패스워드 출력 (Step 5 E2E 실증 접속용)
# -----------------------------------------------------------------------------
output "grafana_admin_password" {
  description = "Grafana 초기 Admin 패스워드 (절대 외부에 노출 금지)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}
