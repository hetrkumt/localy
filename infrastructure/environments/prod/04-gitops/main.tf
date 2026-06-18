# ========================================================================
# Layer 04 — GitOps Bridge Data Hub (SSM 우체통 소비자)
# ========================================================================
# terraform_remote_state 사용 금지.
# EKS/네트워크 정보는 02-compute가 발행한 SSM Parameter만 읽습니다.
# 1차 타격 범위: data 블록 + locals 매핑만 (리소스 생성 없음)
# ========================================================================

# --- Layer 02 Compute SSM Import (아키텍트 팀 확정 경로) ---

data "aws_ssm_parameter" "cluster_name" {
  name = "/localy/prod/compute/cluster_name"
}

data "aws_ssm_parameter" "eks_endpoint" {
  name = "/localy/prod/compute/eks_endpoint"
}

data "aws_ssm_parameter" "eks_ca" {
  name = "/localy/prod/compute/eks_ca"
}

data "aws_ssm_parameter" "oidc_issuer_url" {
  name = "/localy/prod/compute/oidc_issuer_url"
}

# --- SSM → Layer 04 로컬 변수 매핑 (2차 타격 IRSA/Helm에서 참조) ---

locals {
  cluster_name    = data.aws_ssm_parameter.cluster_name.value
  eks_endpoint    = data.aws_ssm_parameter.eks_endpoint.value
  eks_ca          = data.aws_ssm_parameter.eks_ca.value
  oidc_issuer_url = data.aws_ssm_parameter.oidc_issuer_url.value
}
