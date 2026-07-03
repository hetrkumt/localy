# ========================================================================
#    L3 App Integration SSM Parameters - 타 레이어 및 GitOps 간접 참조용 배관 선언
# ========================================================================

resource "aws_ssm_parameter" "loki_bucket_name" {
  name        = local.ssm_paths["loki_bucket_name"]
  type        = "String"
  value       = aws_s3_bucket.loki_logs.id
  description = "The Loki S3 Logs Bucket Name"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

resource "aws_ssm_parameter" "loki_key_arn" {
  name        = local.ssm_paths["loki_key_arn"]
  type        = "String"
  value       = aws_kms_key.loki_s3.arn
  description = "The Loki S3 Encryption KMS Key ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

resource "aws_ssm_parameter" "chatops_topic_arn" {
  name        = local.ssm_paths["chatops_topic_arn"]
  type        = "String"
  value       = aws_sns_topic.chatops_alarm_pipeline.arn
  description = "The ChatOps SNS Topic ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}
