# ========================================================================
#    L3 App Integration Outputs - 타 레이어 및 외부 연동용 아웃풋 명세
# ========================================================================

output "ssm_parameter_paths" {
  description = "The map of SSM parameter paths registered and used in L3 App Integration"
  value       = local.ssm_paths
}
