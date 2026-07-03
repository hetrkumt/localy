# ========================================================================
#    L2 EKS Locals - SSM Parameter 경로 관리 및 접두어 동적 조립
# ========================================================================

locals {
  # 루트 접두어 중앙 정의
  ssm_prefix = "/localy/${var.env_name}"

  # 전사 경로 바인딩 맵 (L1 Read 3개 + L2 Write 15개)
  ssm_paths = {
    # [L1 Network - Read]
    vpc_id             = "${local.ssm_prefix}/network/vpc_id"
    private_subnets    = "${local.ssm_prefix}/network/private_subnets"
    s3_vpc_endpoint_id = "${local.ssm_prefix}/network/s3_vpc_endpoint_id"

    # [L2 EKS Core - Write]
    eks_cluster_name      = "${local.ssm_prefix}/eks/cluster_name"
    eks_cluster_endpoint  = "${local.ssm_prefix}/eks/cluster_endpoint"
    eks_cluster_ca_data   = "${local.ssm_prefix}/eks/cluster_ca_data"
    eks_oidc_provider     = "${local.ssm_prefix}/eks/oidc_provider"
    eks_oidc_provider_arn = "${local.ssm_prefix}/eks/oidc_provider_arn"

    # [L2 EKS IRSA Roles & Queues - Write]
    role_cert_manager_arn             = "${local.ssm_prefix}/eks/roles/cert-manager-arn"
    role_loki_arn                     = "${local.ssm_prefix}/eks/roles/loki-arn"
    role_karpenter_controller_arn     = "${local.ssm_prefix}/eks/roles/karpenter-controller-arn"
    role_karpenter_node_role_name     = "${local.ssm_prefix}/eks/roles/karpenter-node-role-name"
    karpenter_interruption_queue_name = "${local.ssm_prefix}/eks/karpenter-interruption-queue-name"
    role_alb_controller_arn           = "${local.ssm_prefix}/eks/roles/alb-controller-arn"
    role_external_dns_arn             = "${local.ssm_prefix}/eks/roles/external-dns-arn"
    role_ebs_csi_arn                  = "${local.ssm_prefix}/eks/roles/ebs-csi-arn"
    role_grafana_arn                  = "${local.ssm_prefix}/eks/roles/grafana-arn"
    role_alarm_pipeline_sns_arn       = "${local.ssm_prefix}/eks/roles/alarm-pipeline-sns-arn"
  }
}
