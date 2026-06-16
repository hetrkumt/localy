# =============================================================================
# [Step 4] 愿???덉씠???숈쟻 二쇱엯 (Dashboards as Code)
# Grafana Sidecar媛 媛먯???ConfigMap 紐낆꽭??# =============================================================================

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-custom-dashboards"
    namespace = "monitoring"

    # [?듭떖 ?뷀샇] Sidecar 媛먯떆蹂묒씠 ???쇰꺼??蹂닿퀬 ??쒕낫?쒖엫???뚯븘梨뺣땲??
    labels = {
      grafana_dashboard = "1"
    }
  }

  # dashboards ?대뜑???ㅼ슫濡쒕뱶??3媛쒖쓽 JSON ?뚯씪???쎌뼱???ConfigMap???ㅼ뀛 ?ｌ뒿?덈떎.
  data = {
    "k8s-core-metrics.json" = replace(file("${path.module}/dashboards/k8s-core-metrics.json"), "$${DS_PROMETHEUS_TF}", "Prometheus_TF")

    "alb-traffic.json" = replace(file("${path.module}/dashboards/alb-traffic.json"), "$${DS_CLOUDWATCH}", "CloudWatch_TF")

    "karpenter-metrics.json" = file("${path.module}/dashboards/karpenter-metrics.json")
  }

  # 二쇱쓽: ??ConfigMap? 愿?쒗깙(monitoring ?ㅼ엫?ㅽ럹?댁뒪)??議댁옱?댁빞 ?앹꽦 媛?ν빀?덈떎.
  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
