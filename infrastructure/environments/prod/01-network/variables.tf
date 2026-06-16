variable "admin_ip" {
  description = "EKS Control Plane에 접근할 관리자의 공인 IP (CIDR 형식). apply 시점 공인 IP와 함께 public_access_cidrs에 병합됩니다."
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", var.admin_ip))
    error_message = "admin_ip must be a non-empty IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
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

variable "azs" {
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  description = "AWS Availability Zones for VPC subnet placement; length must match public/private/database subnet CIDR lists."
}

variable "public_subnets" {
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  description = "Public subnet CIDR blocks (one per AZ); internet-facing ALB/NAT ingress/egress paths."
}

variable "private_subnets" {
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  description = "Private subnet CIDR blocks (one per AZ); EKS worker nodes and internal workloads."
}

variable "database_subnets" {
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
  description = "Database subnet CIDR blocks (one per AZ); isolated data-tier network segment."
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
