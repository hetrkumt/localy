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

variable "db_master_password_rotation_token" {
  description = <<-EOT
    Reserved for token-based RDS password rotation.
    Today rotate with: terraform apply -replace=random_password.db_password
    To switch to token rotate later, add keepers on random_password.db_password
    (first apply after that will rotate once — use a maintenance window).
    Never rotate via Console put-secret-value or modify-db-instance password.
  EOT
  type        = string
  default     = "initial"
}
