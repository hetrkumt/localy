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

locals {
  alertmanager_cluster_tls_secret_name  = "alertmanager-cluster-tls"
  alertmanager_templates_configmap_name = "alertmanager-templates"
}

# -----------------------------------------------------------------------------
# [Phase 1] Alertmanager gossip mTLS — cert-manager Issuer / Certificate
# Secret 소유권: cert-manager 단독 (Terraform random_password 폐기)
# -----------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

resource "kubernetes_manifest" "alertmanager_cluster_ca_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "alertmanager-cluster-ca"
      namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    }
    spec = {
      selfSigned = {}
    }
  }

  depends_on = [
    kubernetes_service_account_v1.cert_manager_sa,
    kubernetes_namespace_v1.monitoring,
  ]
}

resource "kubernetes_manifest" "alertmanager_cluster_tls_certificate" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = local.alertmanager_cluster_tls_secret_name
      namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    }
    spec = {
      secretName  = local.alertmanager_cluster_tls_secret_name
      duration    = "8760h"
      renewBefore = "720h"
      issuerRef = {
        name = kubernetes_manifest.alertmanager_cluster_ca_issuer.manifest.metadata.name
        kind = "Issuer"
      }
      commonName = "alertmanager-cluster"
      dnsNames = [
        "kube-prometheus-stack-alertmanager",
        "kube-prometheus-stack-alertmanager.monitoring",
        "kube-prometheus-stack-alertmanager.monitoring.svc",
        "kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local",

        "alertmanager-operated",
        "alertmanager-operated.monitoring",
        "alertmanager-operated.monitoring.svc",
        "alertmanager-operated.monitoring.svc.cluster.local",
        "alertmanager-kube-prometheus-stack-alertmanager-0.alertmanager-operated",
        "alertmanager-kube-prometheus-stack-alertmanager-1.alertmanager-operated"
      ]
      ipAddresses = ["127.0.0.1"]
    }
  }

  depends_on = [
    kubernetes_manifest.alertmanager_cluster_ca_issuer,
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