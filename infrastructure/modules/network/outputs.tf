output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private 서브넷 ID 리스트"
  value       = module.vpc.private_subnets
}

output "pod_subnets" {
  description = "VPC CNI Secondary CIDR용 Pod 서브넷 ID 리스트"
  value       = aws_subnet.pod[*].id
}

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway VPC Endpoint ID for zero-trust S3 bucket policies"
  value       = module.vpc_endpoints.endpoints["s3"].id
}

output "sns_vpc_endpoint_id" {
  description = "SNS Interface VPC Endpoint ID for alarm-pipeline private publish"
  value       = aws_vpc_endpoint.sns.id
}

output "sts_vpc_endpoint_id" {
  description = "STS Interface VPC Endpoint ID for IRSA AssumeRoleWithWebIdentity"
  value       = aws_vpc_endpoint.sts.id
}

output "interface_vpc_endpoint_security_group_id" {
  description = "Shared Security Group ID for SNS/STS Interface VPC Endpoints"
  value       = aws_security_group.interface_vpc_endpoint.id
}

output "nat_gateway_public_ips" {
  description = "Elastic IP public addresses bound to NAT Gateway(s)."
  value       = module.vpc.nat_public_ips
}

output "shared_alb_arn" {
  description = "Shared ALB ARN"
  value       = module.alb.lb_arn
}

output "shared_alb_sg_id" {
  description = "Shared ALB Security Group ID"
  value       = aws_security_group.alb.id
}

output "database_subnets" {
  description = "Database 서브넷 ID 리스트"
  value       = module.vpc.database_subnets
}

output "target_groups_map" {
  description = "Safe map of target group keys to ARNs"
  value       = zipmap(local.tg_keys, module.alb.target_group_arns)
}

output "http_listener_arn" {
  description = "The ARN of the shared ALB HTTP listener"
  value       = module.alb.http_tcp_listener_arns[0]
}