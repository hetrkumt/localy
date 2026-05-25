# ========================================================================
# 📡 Ingress Specification (ALB Integration & AWS WAFv2/ACM Chaining)
# ========================================================================
# [설명] 최전방 정문(Ingress) 명세입니다.
# AWS WAFv2 방어막과 AWS ACM 보안 자물쇠가 ALB에 자동으로 찰싹 달라붙도록 체이닝합니다.
# [주의] ALB 환경에서는 쿠버네티스 내부 tls {} 블록을 지원하지 않으므로 전면 배제합니다.
# ========================================================================

resource "kubernetes_ingress_v1" "platform_ingress" {
  metadata {
    name      = "prod-platform-ingress"
    namespace = "default"

    annotations = {
      # -------------------------------------------------------------
      # 🚦 [전술 1] ALB Controller 기동 및 정문 구조 선언
      # -------------------------------------------------------------
      "kubernetes.io/ingress.class"      = "alb"
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"

      # -------------------------------------------------------------
      # 💰 [전술 2] ALB Ingress Grouping (FinOps 최적화)
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/group.name"  = "prod-ingress-group"
      "alb.ingress.kubernetes.io/group.order" = "10"

      # -------------------------------------------------------------
      # ⚡ [전술 3] Target Type 'ip' 모드 고정 (VPC-CNI 다이렉트 라우팅)
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/target-type" = "ip"

      # -------------------------------------------------------------
      # 🛡️ [전술 4] WAFv2 방어막 동적 결합 (IaC 무결성)
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/wafv2-acl-arn" = aws_wafv2_web_acl.ingress_waf.arn

      # -------------------------------------------------------------
      # 🔒 [전술 피벗] AWS ACM 공인 인증서 결합 및 HTTPS 강제 리다이렉트
      # -------------------------------------------------------------
      # 테라폼이 Route 53 검증을 완료한 ACM 인증서의 실제 주소(ARN)를 결합합니다.
      "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.prod_cert_validation.certificate_arn

      # ALB가 HTTP(80)와 HTTPS(443) 두 개의 포트를 모두 열도록 강제합니다.
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}, {\"HTTPS\":443}]"

      # HTTP(80)로 들어온 트래픽을 안전한 HTTPS(443)로 자동 전환(Redirect)시킵니다.
      "alb.ingress.kubernetes.io/ssl-redirect" = "443"
    }
  }

  spec {
    # ❌ [리드 아키텍트 지시] 기존 tls {} 블록 전면 삭제 (ALB는 K8s Secret을 읽을 수 없음)

    rule {
      host = "feifo.click" # 도메인 명시하여 해당 트래픽 수신
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.target_svc.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # [의존성 제어] ALB 컨트롤러와 타겟 애플리케이션 서비스가 먼저 준비되어 있어야 정문을 개통합니다.
  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_service_v1.target_svc
  ]
}
