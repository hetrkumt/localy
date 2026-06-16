variable "admin_ip" {
  description = "EKS Control Plane에 접근할 관리자의 공인 IP (CIDR 형식). apply 시점 공인 IP와 함께 public_access_cidrs에 병합됩니다."
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", var.admin_ip))
    error_message = "admin_ip must be a non-empty IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
}

variable "allow_global_cluster_api_access" {
  description = "EKS Control Plane의 퍼블릭 엔드포인트를 0.0.0.0/0으로 개방할지 여부. true이면 public_access_cidrs에 0.0.0.0/0 추가 (임시 프로비저닝용). 보안상 false 권장."
  type        = bool
  default     = false
}
