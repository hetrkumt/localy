output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private 서브넷 ID 리스트"
  value       = module.vpc.private_subnets
}

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway VPC Endpoint ID for zero-trust S3 bucket policies"
  value       = module.vpc_endpoints.endpoints["s3"].id
}