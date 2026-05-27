# -------------------------------------------------------------------------
# ExternalDNS Helm Release 배포
# -------------------------------------------------------------------------
# ExternalDNS Helm 차트를 kube-system 네임스페이스에 배포하며,
# 1단계에서 생성한 ServiceAccount에 IRSA 역할을 안전하게 결합합니다.
# -------------------------------------------------------------------------
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = "kube-system"

  version = "1.14.3"

  # 1단계에서 만든 ServiceAccount가 완전히 준비된 이후에만 Helm Release 실행
  depends_on = [
    kubernetes_service_account_v1.external_dns_sa,
    helm_release.aws_load_balancer_controller
  ]

  # IRSA ServiceAccount를 재사용하여 중복 생성과 권한 누수를 방지합니다.
  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.external_dns_sa.metadata[0].name
  }

  # ExternalDNS가 AWS Route53에만 집중하도록 프로바이더와 소스를 고정
  set {
    name  = "provider"
    value = "aws"
  }

  set {
    name  = "source"
    value = "ingress"
  }

  # 특정 도메인 영역만 관리하도록 제한하여 도메인 범위를 좁힙니다.
  set {
    name  = "domainFilters[0]"
    value = "feifo.click"
  }

  # 레코드 삭제를 방지하는 안전 모드로 설정합니다.
  set {
    name  = "policy"
    value = "upsert-only"
  }

  # 클러스터 고유 식별자 태그를 추가하여 멀티클러스터 환경 구분에 기여합니다.
  set {
    name  = "txtOwnerId"
    value = "prod-platform-eks"
  }

  # 메트릭 포트는 열어두되, ServiceMonitor는 비활성화하여
  # Prometheus Operator 미존재로 인한 배포 실패를 방지합니다.
  set {
    name  = "metrics.enabled"
    value = "true"
  }

  set {
    name  = "serviceMonitor.enabled"
    value = "false"
  }
}
