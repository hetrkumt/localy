# ========================================================================
# Layer 04 — GitOps Bridge State (완전 격리)
# ========================================================================
# Key 패턴: eks-gitops/prod/<layer>.tfstate
# terraform_remote_state 사용 금지 — SSM Parameter Store 우체통만 허용
# ========================================================================

terraform {
  backend "s3" {
    bucket       = "feifo-prod-tf-state-backend"
    key          = "eks-gitops/prod/04-gitops.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}
