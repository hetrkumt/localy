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
            name      = "Prometheus TF"
            type      = "prometheus"
            uid       = "Prometheus_TF"  
            url       = "http://kube-prometheus-stack-prometheus.monitoring:9090"
            access    = "proxy"
          },
          {
            name      = "Prometheus LBC"
            type      = "prometheus"
            uid       = "Prometheus_LBC"  
            url       = "http://kube-prometheus-stack-prometheus.monitoring:9090"
            access    = "proxy"
          },
          {
            name   = "CloudWatch"
            type   = "cloudwatch"
            uid    = "CloudWatch_TF"
            access = "proxy"
            jsonData = {
              authType      = "default"          # EKS 워커 노드에 부여된 IAM 권한을 그대로 상속받음
              defaultRegion = "ap-northeast-2"   # 서울 리전 타겟팅
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
            "alb.ingress.kubernetes.io/group.name" = "prod-ingress-group"
            "alb.ingress.kubernetes.io/target-type" = "ip"
            "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTPS\":443}]"
            
						# 3. acm.tf 리소스를 직접 바라보도록 'data.' 제거
						"alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate.prod_cert.arn
						
						# 4. waf.tf의 실제 리소스 이름인 'ingress_waf'로 명칭 교정
						"alb.ingress.kubernetes.io/wafv2-acl-arn"   = aws_wafv2_web_acl.ingress_waf.arn
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
