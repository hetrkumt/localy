terraform {
  backend "s3" {
    bucket       = "feifo-prod-tf-state-backend"
    key          = "eks-gitops/prod/01-network.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}
