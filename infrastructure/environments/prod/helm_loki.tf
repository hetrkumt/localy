# =============================================================================
# [Frame 2 — Loki] Grafana Loki Helm Release (SimpleScalable → observability)
# =============================================================================

# [DevSecOps] IAM 및 S3 정책의 AWS 글로벌 복제(전파) 대기 족쇄
# data.aws_region.current → kms_loki.tf
resource "time_sleep" "wait_for_iam_and_s3_propagation" {
  depends_on = [
    aws_iam_role_policy.loki_s3,
    aws_s3_bucket_policy.loki_logs
  ]
  create_duration = "30s"
}

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "5.47.2"
  namespace        = "observability"
  create_namespace = true
  wait             = true
  timeout          = 600

  # [FinOps/DevSecOps] templatefile을 통한 무결성 동적 주입
  values = [
    templatefile("${path.module}/loki-values.yaml", {
      loki_irsa_role_arn  = aws_iam_role.loki.arn
      loki_s3_bucket_name = aws_s3_bucket.loki_logs.id
      aws_region          = data.aws_region.current.name # 
    })
    
  ]

  depends_on = [
    module.eks,
    aws_kms_key.loki_s3,
    aws_s3_bucket_server_side_encryption_configuration.loki_logs,
    time_sleep.wait_for_iam_and_s3_propagation, # 30초 대기 족쇄 결속
    helm_release.aws_load_balancer_controller
  ]
  set {
    name  = "gateway.service.annotations.service\\.kubernetes\\.io/topology-mode"
    value = "auto"  # 🚨 [FinOps 족쇄] Cross-AZ 네트워크 과금 원천 차단
  }
}

# NetworkPolicy → k8s_network_policy.tf (kubernetes_network_policy_v1)