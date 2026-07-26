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

# ========================================================================
# Store Service — SSM Parameter 배관 (ESO 및 매니페스트 간접 참조용)
# ========================================================================

resource "aws_ssm_parameter" "store_bucket_name" {
  name        = local.ssm_paths["store_bucket_name"]
  type        = "String"
  value       = aws_s3_bucket.store_images.id
  description = "The store-service S3 Images Bucket Name"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

resource "aws_ssm_parameter" "store_key_arn" {
  name        = local.ssm_paths["store_key_arn"]
  type        = "String"
  value       = aws_kms_key.store_s3.arn
  description = "The store-service S3 Encryption KMS Key ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

resource "aws_ssm_parameter" "store_role_arn" {
  name        = local.ssm_paths["store_role_arn"]
  type        = "String"
  value       = aws_iam_role.store_service.arn
  description = "The store-service Pod Identity IAM Role ARN"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

# ========================================================================
# MSK Parameter (ESO �� KEDA ������)
# ========================================================================
resource "aws_ssm_parameter" "msk_bootstrap_servers" {
  name        = local.ssm_paths["msk_bootstrap_servers"]
  type        = "String"
  value       = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
  description = "The MSK IAM Auth Bootstrap Servers"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}


# ========================================================================
# Missing WAF & ACM Parameters (GitOps 보수)
# ========================================================================

resource "aws_ssm_parameter" "waf_arn" {
  name        = local.ssm_paths["waf_arn"]
  type        = "String"
  value       = aws_wafv2_web_acl.ingress_waf.arn
  description = "The ARN of the WAFv2 Web ACL"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

resource "aws_ssm_parameter" "acm_arn" {
  name        = local.ssm_paths["acm_arn"]
  type        = "String"
  value       = aws_acm_certificate.prod_cert.arn
  description = "The ARN of the ACM Certificate"

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Layer       = "l3-app-integration"
  }
}

