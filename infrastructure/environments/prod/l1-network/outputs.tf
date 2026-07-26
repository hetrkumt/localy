output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.network.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.network.private_subnets
}

# [신규 추가] Pod 서브넷 출력
output "pod_subnets" {
  description = "List of IDs of EKS pod subnets (Secondary CIDR)"
  value       = module.network.pod_subnets
}

# [긴급 보수] 데이터베이스 서브넷 출력
output "database_subnets" {
  description = "List of IDs of database subnets"
  value       = module.network.database_subnets
}

# [신규 추가] ALB ARN 출력
output "shared_alb_arn" {
  description = "Shared ALB ARN for TargetGroupBinding mapping"
  value       = module.network.shared_alb_arn
}

output "ssm_parameter_paths" {
  description = "The map of SSM parameter paths registered in L1 Network"
  value       = local.ssm_paths
}

output "target_groups_map" {
  description = "Safe map of target group keys to ARNs"
  value       = module.network.target_groups_map
}
