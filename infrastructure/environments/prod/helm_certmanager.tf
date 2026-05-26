# ========================================================================
# 🛡️ Phase 2: Cert-Manager Helm Release 배포
# ========================================================================
# [설명] Let's Encrypt와 통신하여 공인 인증서를 자동으로 발급받고 갱신해 주는
# 인증서 공장장(Cert-Manager) 로봇을 EKS 클러스터 내부에 투하합니다.
# ========================================================================

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = "cert-manager"
  version    = "v1.14.4"

  # Cert-Manager는 Certificate, ClusterIssuer라는 고유한 쿠버네티스 문법(CRD)을 사용합니다.
  # 이를 true로 켜주지 않으면, Phase 3에서 만들 설계도를 쿠버네티스가 이해하지 못합니다.
  set {
    name  = "installCRDs"
    value = "true"
  }

  # -------------------------------------------------------------
  # 🛡️ [핵심 2] 신분증(SA) 보호 및 덮어쓰기 방지
  # -------------------------------------------------------------
  # Helm 차트가 깡통 서비스 어카운트(SA)를 임의로 만들어서,
  # 우리가 Phase 1에서 만든 IRSA 명품 신분증을 덮어쓰는 대참사를 막습니다.
  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.cert_manager_sa.metadata[0].name
  }

  # -------------------------------------------------------------
  # ⛓️ [핵심 3] 레이스 컨디션(Race Condition) 방어
  # -------------------------------------------------------------
  # Phase 1의 신분증(SA) 생성이 쿠버네티스 API 서버에 100% 완료된 후에야
  # 로봇(Helm) 설치를 시작하도록 테라폼의 실행 순서(DAG)를 엄격히 직렬화합니다.
  depends_on = [
    kubernetes_service_account_v1.cert_manager_sa,
    helm_release.aws_load_balancer_controller,
  ]
}
