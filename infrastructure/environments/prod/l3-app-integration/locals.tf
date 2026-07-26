# ========================================================================
#    L3 App Integration Locals - SSM Parameter 경로 관리 및 접두어 조립
# ========================================================================

locals {
  # 루트 접두어 중앙 정의
  ssm_prefix = "/localy/${var.env_name}"

  # 전사 경로 바인딩 맵 (L1 Read 4개 + L2 Read 6개 + L3 Write 3개)
  ssm_paths = {
    # [L1 Network - Read]
    vpc_id             = "${local.ssm_prefix}/network/vpc_id"
    private_subnets    = "${local.ssm_prefix}/network/private_subnets"
    database_subnets   = "${local.ssm_prefix}/network/database_subnets" # 보수반영
    s3_vpc_endpoint_id = "${local.ssm_prefix}/network/s3_vpc_endpoint_id"

    # [L2 EKS Core & IAM - Read]
    eks_cluster_name               = "${local.ssm_prefix}/eks/cluster_name"
    eks_oidc_provider              = "${local.ssm_prefix}/eks/oidc_provider"
    eks_oidc_provider_arn          = "${local.ssm_prefix}/eks/oidc_provider_arn"
    role_loki_arn                  = "${local.ssm_prefix}/eks/roles/loki-arn"
    role_alarm_pipeline_sns_arn    = "${local.ssm_prefix}/eks/roles/alarm-pipeline-sns-arn"
    role_workload_pod_identity_arn = "${local.ssm_prefix}/eks/roles/workload-pod-identity-arn" # 연계 반영

    # [L3 Outputs - Write]
    loki_bucket_name  = "${local.ssm_prefix}/apps/s3/loki_bucket_name"
    loki_key_arn      = "${local.ssm_prefix}/apps/kms/loki_key_arn"
    chatops_topic_arn = "${local.ssm_prefix}/apps/sns/chatops_topic_arn"
    waf_arn           = "${local.ssm_prefix}/apps/waf/arn"
    acm_arn           = "${local.ssm_prefix}/apps/acm/cert_arn"

    # [L3 Outputs - Store Service]
    store_bucket_name = "${local.ssm_prefix}/apps/s3/store_bucket_name"
    store_key_arn     = "${local.ssm_prefix}/apps/kms/store_key_arn"
    store_role_arn    = "${local.ssm_prefix}/apps/iam/store_role_arn"

    # [L3 Outputs - Payment Service]
    msk_bootstrap_servers = "${local.ssm_prefix}/apps/msk/bootstrap_servers"
  }
}
