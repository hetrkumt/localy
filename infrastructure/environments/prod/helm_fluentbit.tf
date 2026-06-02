# =============================================================================
# [Frame 2 — Fluent Bit] 로그 수집 DaemonSet (monitoring → Loki push)
# =============================================================================

resource "helm_release" "fluent_bit" {
  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  version          = "0.47.10"
  namespace        = "monitoring"
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    file("${path.module}/fluent-bit-values.yaml")
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki,
  ]
}
