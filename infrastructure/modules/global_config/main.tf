locals {
  env_name     = "prod"
  project      = "localy"
  region       = "ap-northeast-2"
  base_domain  = "feifo.click"
  cluster_name = "prod-eks"

  common_tags = {
    Environment = local.env_name
    Project     = local.project
    ManagedBy   = "Terraform"
  }
}

output "env_name" {
  value = local.env_name
}

output "project" {
  value = local.project
}

output "region" {
  value = local.region
}

output "base_domain" {
  value = local.base_domain
}

output "cluster_name" {
  value = local.cluster_name
}

output "common_tags" {
  value = local.common_tags
}
