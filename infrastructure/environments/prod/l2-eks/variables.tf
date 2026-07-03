variable "env_name" {
  type    = string
  default = "prod"
}

variable "admin_ip" {
  description = "EKS Control Plane에 접근할 관리자의 공인 IP (CIDR 형식)"
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", var.admin_ip))
    error_message = "admin_ip must be a non-empty IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
}

variable "allow_global_cluster_api_access" {
  description = "true이면 public_access_cidrs에 0.0.0.0/0 추가"
  type        = bool
  default     = false
}

variable "chatops_sre_slack_user_ids" {
  description = "JIT log access authorized SRE Slack user IDs (e.g. [\"U01ABCDEF\"])"
  type        = list(string)

  validation {
    condition     = length(var.chatops_sre_slack_user_ids) > 0
    error_message = "chatops_sre_slack_user_ids must contain at least one Slack user ID."
  }

  validation {
    condition = alltrue([
      for id in var.chatops_sre_slack_user_ids : can(regex("^U[A-Z0-9]{8,}$", id))
    ])
    error_message = "Each chatops_sre_slack_user_ids entry must be a Slack user ID matching ^U[A-Z0-9]{8,}$."
  }
}
