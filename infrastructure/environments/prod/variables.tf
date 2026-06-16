variable "env_name" {
  type    = string
  default = "prod"
}

variable "base_domain" {
  type        = string
  default     = "feifo.click"
  description = "Base domain name"
}

variable "cluster_name" {
  type        = string
  default     = "prod-eks"
  description = "EKS cluster name"
}

variable "vpc_cidr_block" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR block"

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr_block))
    error_message = "vpc_cidr_block must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }
}

variable "admin_ip" {
  description = "EKS Control Plane에 접근할 관리자의 공인 IP (CIDR 형식). apply 시점 공인 IP와 함께 public_access_cidrs에 병합됩니다."
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", var.admin_ip))
    error_message = "admin_ip must be a non-empty IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
}

variable "allow_global_cluster_api_access" {
  description = "true이면 public_access_cidrs에 0.0.0.0/0 추가 (임시 프로비저닝용, 운영 전 false 권장)"
  type        = bool
  default     = false
}

variable "s3_bucket_policy_bypass_principal_arns" {
  description = "Loki S3 zero-trust Deny 예외 IAM principal ARN (CI/CD·Admin Role 등). apply 주체는 aws_iam_session_context로 자동 병합."
  type        = list(string)
  default     = []
}

variable "chatops_sre_slack_user_ids" {
  description = "JIT log access authorized SRE Slack user IDs (e.g. [\"U01ABCDEF\"]). Injected into auth Lambda env."
  type        = list(string)
  default     = ["U01ABCDEF"]

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