output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.network.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.network.private_subnets
}

output "ssm_parameter_paths" {
  description = "The map of SSM parameter paths registered in L1 Network"
  value       = local.ssm_paths
}
