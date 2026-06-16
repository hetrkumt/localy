# =============================================================================
# [Step 4] 관제 레이더 동적 주입 (Dashboards as Code)
# Grafana Sidecar가 감지할 ConfigMap 명세서
# =============================================================================

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-custom-dashboards"
    namespace = "monitoring"
    
    # [핵심 암호] Sidecar 감시병이 이 라벨을 보고 대시보드임을 알아챕니다!
    labels = {
      grafana_dashboard = "1" 
    }
  }

  # dashboards 폴더에 다운로드한 3개의 JSON 파일을 읽어와서 ConfigMap에 쑤셔 넣습니다.
	data = {
    "k8s-core-metrics.json"  = replace(file("${path.module}/dashboards/k8s-core-metrics.json"), "$${DS_PROMETHEUS_TF}", "Prometheus_TF")
    
    "alb-traffic.json" = replace(file("${path.module}/dashboards/alb-traffic.json"), "$${DS_CLOUDWATCH}", "CloudWatch_TF")

    "karpenter-metrics.json" = file("${path.module}/dashboards/karpenter-metrics.json")
  }

  # 주의: 이 ConfigMap은 관제탑(monitoring 네임스페이스)이 존재해야 생성 가능합니다.
  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}