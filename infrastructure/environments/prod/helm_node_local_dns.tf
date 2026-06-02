# =============================================================================
# NodeLocal DNSCache — kube-system (Fluent Bit / Loki gateway DNS 안정화)
# Chart: deliveryhero/node-local-dns (community; kubernetes-sigs는 공식 Helm 미제공)
# apply 전: kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}'
# =============================================================================

resource "helm_release" "node_local_dns" {
  name             = "node-local-dns"
  repository       = "https://charts.deliveryhero.io/"
  chart            = "node-local-dns"
  version          = "2.8.0"
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  timeout          = 600

  depends_on = [
    module.eks,
  ]

  set {
    name  = "config.dnsDomain"
    value = "cluster.local"
  }

  set {
    name  = "config.localDns"
    value = "169.254.20.10"
  }

  # EKS kube-dns ClusterIP — 클러스터마다 plan/apply 전 확인 권장
  set {
    name  = "config.dnsServer"
    value = "172.20.0.10"
  }

  set {
    name  = "config.bindIp"
    value = "true"
  }

  set {
    name  = "config.prefetch.enabled"
    value = "true"
  }

  set {
    name  = "serviceMonitor.enabled"
    value = "true"
  }

  set {
    name  = "serviceMonitor.labels.release"
    value = "kube-prometheus-stack"
  }

  set {
    name  = "prometheusScraping.enabled"
    value = "true"
  }

  # [SRE] DNS 롤링 업데이트 블랙홀 방어 — 노드당 1 Pod만 동시 교체
  set {
    name  = "updateStrategy.rollingUpdate.maxUnavailable"
    value = "1"
  }

  # [SRE] preStop 골든타임 — iptables/DNS 캐시 롤백 전 5s 유예
  set {
    name  = "lifecycle.preStop.exec.command[0]"
    value = "/bin/sh"
  }
  set {
    name  = "lifecycle.preStop.exec.command[1]"
    value = "-c"
  }
  set {
    name  = "lifecycle.preStop.exec.command[2]"
    value = "sleep 5"
  }

  # [FinOps] DaemonSet Tax — chart 기본(25m/128Mi) 대비 하향
  set {
    name  = "resources.requests.cpu"
    value = "10m"
  }
  set {
    name  = "resources.requests.memory"
    value = "30Mi"
  }
}
