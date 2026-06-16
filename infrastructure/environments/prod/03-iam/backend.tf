terraform {
  backend "s3" {
    bucket       = "feifo-prod-tf-state-backend"
    key          = "eks-gitops/prod/03-iam.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
  }
}
