# Phase 3 - Kyverno variables temporarily placed in layer 03

variable "kyverno_namespace" {
  description = "Kyverno Helm release namespace"
  type        = string
  default     = "kyverno"
}

variable "kyverno_admission_webhook_port" {
  description = "Kyverno admission Service targetPort"
  type        = number
  default     = 9443
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

variable "s3_bucket_policy_bypass_principal_arns" {
  description = "Loki S3 zero-trust Deny bypass IAM principal ARNs (CI/CD and Admin roles)."
  type        = list(string)
  default     = []
}

variable "chatops_sre_slack_user_ids" {
  description = "JIT log access authorized SRE Slack user IDs."
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
