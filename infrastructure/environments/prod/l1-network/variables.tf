variable "env_name" {
  type    = string
  default = "prod"
}

variable "s3_bucket_policy_bypass_principal_arns" {
  description = "Loki S3 zero-trust Deny 예외 IAM principal ARN (CI/CD·Admin Role 등)"
  type        = list(string)
  default     = []
}
