# ========================================================================
# Network — EKS outbound NAT EIP (Slack IP Allowlist 결속용)
# ========================================================================

output "eks_nat_gateway_public_ips" {
  description = "NAT Gateway Elastic IPs for EKS cluster outbound traffic. Register in Slack API IP Allowlist."
  value       = module.network.nat_gateway_public_ips
}

output "eks_nat_gateway_public_ip_cidrs" {
  description = "NAT Gateway EIPs as /32 CIDRs for SaaS allowlist binding."
  value       = module.network.nat_gateway_public_ip_cidrs
}

output "eks_nat_gateway_count" {
  description = "Active NAT Gateway count (verify all IPs are allowlisted when > 1)."
  value       = module.network.nat_gateway_count
}
