# =============================================================================
# [Frame 2 — Loki] IAM/S3 전파 대기 (ArgoCD 배포 전 Terraform 선행 작업)
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

# NetworkPolicy → k8s_network_policy.tf (kubernetes_network_policy_v1)
