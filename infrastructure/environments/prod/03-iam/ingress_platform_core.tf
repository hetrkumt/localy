# ========================================================================
# ?뱻 Ingress Specification (ALB Integration & AWS WAFv2/ACM Chaining)
# ========================================================================
# [?ㅻ챸] 理쒖쟾諛??뺣Ц(Ingress) 紐낆꽭?낅땲??
# AWS WAFv2 諛⑹뼱留됯낵 AWS ACM 蹂댁븞 ?먮Ъ?좉? ALB???먮룞?쇰줈 李곗떦 ?щ씪遺숇룄濡?泥댁씠?앺빀?덈떎.
# [二쇱쓽] ALB ?섍꼍?먯꽌??荑좊쾭?ㅽ떚???대? tls {} 釉붾줉??吏?먰븯吏 ?딆쑝誘濡??꾨㈃ 諛곗젣?⑸땲??
# ========================================================================

# ========================================================================

data "aws_wafv2_web_acl" "ingress_waf" {
  name  = "prod-ingress-waf"
  scope = "REGIONAL"
}

data "aws_acm_certificate" "prod_cert" {
  domain      = module.global.base_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "kubernetes_ingress_v1" "platform_ingress" {
  metadata {
    name      = "prod-platform-ingress"
    namespace = "default"

    annotations = {
      # -------------------------------------------------------------
      # ?슗 [?꾩닠 1] ALB Controller 湲곕룞 諛??뺣Ц 援ъ“ ?좎뼵
      # -------------------------------------------------------------
      "kubernetes.io/ingress.class"      = "alb"
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"

      # -------------------------------------------------------------
      # ?뮥 [?꾩닠 2] ALB Ingress Grouping (FinOps 理쒖쟻??
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/group.name"  = "prod-ingress-group"
      "alb.ingress.kubernetes.io/group.order" = "10"

      # -------------------------------------------------------------
      # ??[?꾩닠 3] Target Type 'ip' 紐⑤뱶 怨좎젙 (VPC-CNI ?ㅼ씠?됲듃 ?쇱슦??
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/target-type" = "ip"

      # -------------------------------------------------------------
      # ?썳截?[?꾩닠 4] WAFv2 諛⑹뼱留??숈쟻 寃고빀 (IaC 臾닿껐??
      # -------------------------------------------------------------
      "alb.ingress.kubernetes.io/wafv2-acl-arn" = data.aws_wafv2_web_acl.ingress_waf.arn

      # -------------------------------------------------------------
      # ?뵏 [?꾩닠 ?쇰쿁] AWS ACM 怨듭씤 ?몄쬆??寃고빀 諛?HTTPS 媛뺤젣 由щ떎?대젆??      # -------------------------------------------------------------
      # ?뚮씪?쇱씠 Route 53 寃利앹쓣 ?꾨즺??ACM ?몄쬆?쒖쓽 ?ㅼ젣 二쇱냼(ARN)瑜?寃고빀?⑸땲??
      "alb.ingress.kubernetes.io/certificate-arn" = data.aws_acm_certificate.prod_cert.arn

      # ALB媛 HTTP(80)? HTTPS(443) ??媛쒖쓽 ?ы듃瑜?紐⑤몢 ?대룄濡?媛뺤젣?⑸땲??
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}, {\"HTTPS\":443}]"

      # HTTP(80)濡??ㅼ뼱???몃옒?쎌쓣 ?덉쟾??HTTPS(443)濡??먮룞 ?꾪솚(Redirect)?쒗궢?덈떎.
      "alb.ingress.kubernetes.io/ssl-redirect" = "443"
    }
  }

  spec {
    # ??[由щ뱶 ?꾪궎?랁듃 吏?? 湲곗〈 tls {} 釉붾줉 ?꾨㈃ ??젣 (ALB??K8s Secret???쎌쓣 ???놁쓬)

    rule {
      host = module.global.base_domain # ?꾨찓??紐낆떆?섏뿬 ?대떦 ?몃옒???섏떊
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

  # [?섏〈???쒖뼱] ALB 而⑦듃濡ㅻ윭? ?寃??좏뵆由ъ??댁뀡 ?쒕퉬?ㅺ? 癒쇱? 以鍮꾨릺???덉뼱???뺣Ц??媛쒗넻?⑸땲??
  depends_on = [
    kubernetes_service_account_v1.aws_lbc_sa,
    kubernetes_service_v1.target_svc,
  ]
}
