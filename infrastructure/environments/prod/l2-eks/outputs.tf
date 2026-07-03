output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS Cluster Endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "EKS Cluster Certificate Authority Data"
  value       = module.eks.cluster_certificate_authority_data
}

output "eks_oidc_provider_arn" {
  description = "EKS Cluster OIDC Provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "eks_cluster_oidc_issuer_url" {
  description = "EKS Cluster OIDC Issuer URL"
  value       = module.eks.cluster_oidc_issuer_url
}

output "ssm_parameter_paths" {
  description = "The map of SSM parameter paths registered and used in L2 EKS"
  value       = local.ssm_paths
}
