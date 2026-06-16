variable "role_name" {
  type = string
}

variable "namespace" {
  type = string
}

variable "serviceaccount_name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "custom_policy_json" {
  type        = string
  description = "개발자가 요청하는 Allow 권한 JSON. 반드시 data.aws_iam_policy_document 결과값만 주입할 것."
}
