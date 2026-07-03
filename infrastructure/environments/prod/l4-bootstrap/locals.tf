# ========================================================================
#    L4 Bootstrap Locals - SSM Parameter 경로 관리 및 접두어 조립
# ========================================================================

locals {
  # 루트 접두어 중앙 정의
  ssm_prefix = "/localy/${var.env_name}"

  # 전사 경로 바인딩 맵 (L2 Read 3개)
  ssm_paths = {
    eks_cluster_name     = "${local.ssm_prefix}/eks/cluster_name"
    eks_cluster_endpoint = "${local.ssm_prefix}/eks/cluster_endpoint"
    eks_cluster_ca_data  = "${local.ssm_prefix}/eks/cluster_ca_data"
  }
}
