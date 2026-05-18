# -------------------------------------------------------------------------
# AWS WAFv2 Web ACL for ALB Ingress
# -------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "ingress_waf" {
  name        = "prod-ingress-waf"
  description = "WAF for Production ALB Ingress (Managed Rules)"
  scope       = "REGIONAL" 

  default_action {
    allow {} 
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "prod-ingress-waf-metric"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# -------------------------------------------------------------------------
# 1. WAFv2 전용 로그 저장소 (S3 버킷 본체)
# -------------------------------------------------------------------------
resource "aws_s3_bucket" "waf_logs" {
  bucket        = "aws-waf-logs-localy-prod-audit"
  force_destroy = true 

  tags = {
    Name        = "aws-waf-logs-localy-prod-audit"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# FinOps 정책 - 무제한 비용 증가 방지를 위한 14일 자동 파기
resource "aws_s3_bucket_lifecycle_configuration" "waf_logs_lifecycle" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    id     = "waf-log-expiration-policy"
    status = "Enabled"

    filter {}

    expiration {
      days = 14 
    }
  }
}

# 보안 컴플라이언스 정책 - ISMS-P 심사 통과를 위한 SSE-S3 암호화 명시
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs_encryption" {
  bucket = aws_s3_bucket.waf_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" 
    }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs_public_access_block" {
  bucket = aws_s3_bucket.waf_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------------------------------------------------------
# 2. WAFv2 Web ACL - S3 로깅 파이프라인 결합
# -------------------------------------------------------------------------
resource "aws_wafv2_web_acl_logging_configuration" "ingress_waf_logging" {
  log_destination_configs = [aws_s3_bucket.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.ingress_waf.arn
}

# -------------------------------------------------------------------------
# Outputs - GitOps 및 Ingress 연동을 위한 WAF ARN 외치기
# -------------------------------------------------------------------------
output "ingress_waf_arn" {
  description = "The ARN of the WAFv2 Web ACL to be used in ALB Ingress annotations"
  value       = aws_wafv2_web_acl.ingress_waf.arn
}
