# =============================================================================
# [Phase 4] Alertmanager Notification Templates (Thin TF / Fat Artifact)
# Mount: alertmanagerSpec.configMaps -> /etc/alertmanager/configmaps/alertmanager-templates/
# Load:  alertmanager.config.templates glob (*.tmpl)
# =============================================================================

locals {
  alertmanager_templates_configmap_name = "alertmanager-templates"
}

resource "kubernetes_config_map_v1" "alertmanager_templates" {
  metadata {
    name      = local.alertmanager_templates_configmap_name
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "notification-templates"
      "app.kubernetes.io/part-of"   = "alarm-pipeline"
      "managed-by"                  = "terraform"
    }
  }

  data = {
    "chatops-top3.tmpl" = file("${path.module}/alertmanager-templates/chatops-top3.tmpl")
  }

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
