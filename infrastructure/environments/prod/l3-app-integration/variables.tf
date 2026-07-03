variable "env_name" {
  type    = string
  default = "prod"
}

variable "s3_bucket_policy_bypass_principal_arns" {
  description = "S3 zero-trust Deny 예외 IAM principal ARN (CI/CD·Admin Role 등)"
  type        = list(string)
  default     = []
}

variable "chatops_sre_slack_user_ids" {
  description = "JIT 권한을 승인할 SRE Slack User ID 목록"
  type        = list(string)
  default     = ["U12345678"]
}

variable "admin_ip" {
  type    = string
  default = "121.162.247.165/32"
}
