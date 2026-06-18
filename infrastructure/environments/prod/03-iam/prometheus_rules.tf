# =============================================================================
# [Phase 2] Alarm Pipeline ??PrometheusRule (Thin TF / Fat YAML)
# CRD 寃곗냽: release=kube-prometheus-stack ??Prometheus Operator auto-discovery
# =============================================================================

resource "kubectl_manifest" "prometheus_rule_alarm_pipeline" {
  yaml_body = file("${path.module}/prometheus-rules/alarm-pipeline.yaml")

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
} 
