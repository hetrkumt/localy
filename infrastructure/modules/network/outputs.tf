output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private 서브넷 ID 리스트"
  value       = module.vpc.private_subnets
}