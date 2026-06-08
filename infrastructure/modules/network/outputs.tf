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

output "nat_gateway_public_ips" {
  description = "Elastic IP public addresses bound to NAT Gateway(s). EKS private subnet outbound (Slack API etc.) egress IPs."
  value       = module.vpc.nat_public_ips
}

output "nat_gateway_public_ip_cidrs" {
  description = "NAT Gateway EIPs as /32 CIDR blocks for SaaS IP allowlists (e.g. Slack API dashboard)."
  value       = [for ip in module.vpc.nat_public_ips : "${ip}/32"]
}

output "nat_gateway_count" {
  description = "Number of NAT Gateways (1 = single_nat_gateway, N = one_nat_gateway_per_az)."
  value       = length(module.vpc.nat_public_ips)
}