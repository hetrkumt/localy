# ========================================================================
# CloudTrail — Loki Vault Data Events Precision Audit (FinOps Guarded)
# ========================================================================

data "aws_caller_identity" "cloudtrail" {}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${var.env_name}-eks-cloudtrail-audit-logs"

  tags = {
    Name        = "${var.env_name}-eks-cloudtrail-audit-logs"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "cloudtrail-audit-logs"
  }
   
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id

  rule {
    id     = "cloudtrail-log-retention"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_logs_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:GetBucketAcl"]

    resources = [
      aws_s3_bucket.cloudtrail_logs.arn
    ]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.cloudtrail.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs_bucket.json
}

resource "aws_cloudtrail" "loki_vault_data_events" {
  name                          = "${var.env_name}-loki-vault-data-events-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = false
  is_multi_region_trail         = false
  enable_logging                = true
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "LokiVaultObjectDataEvents"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.loki_logs.arn}/"]
    }

    field_selector {
      field  = "eventName"
      equals = ["GetObject", "PutObject", "DeleteObject"]
    }
    # -------------------------------------------------------------------------
    # 💡 [FinOps & DevSecOps] Loki S3 Data Event 과금 방어용 예외 처리
    # 
    # [배경 및 목적]
    # - Loki의 일상적이고 방대한 S3 Get/Put API 호출을 CloudTrail에 모두 기록할 경우 
    #   막대한 데이터 이벤트 과금이 발생하므로, Loki IRSA 권한은 로깅에서 제외함.
    # 
    # [보안 사각지대 보완책 (Defense in Depth)]
    # - CloudTrail 제외로 인한 보안 위험은 아래의 다중 방어망으로 통제됨:
    #   1. 외부 반출 원천 봉쇄: IAM SourceVpc 및 S3 VPC Endpoint(VPCE) 정책으로 내부망 외 접근 불가
    #   2. 데이터 변조 차단: S3 Object Lock (Compliance 90일) 적용으로 크립토 슈레딩/랜섬웨어 방어
    #   3. 대량 탈취 방어: AWS Budgets 서킷 브레이커 연동으로 비정상적 비용(트래픽) 급증 시 즉시 접근 차단
    # 
    # [TODO/Next Step]
    # - 추후 ISMS-P 등 엄격한 컴플라이언스 감사가 필요해질 경우, 
    #   비용이 저렴한 'S3 Server Access Logging'을 추가 활성화하여 이 사각지대를 완전히 해소할 수 있음.
    # -------------------------------------------------------------------------
    field_selector {
      field = "userIdentity.arn"
      not_starts_with = [
        format(
          "arn:aws:sts::%s:assumed-role/%s/",
          data.aws_caller_identity.cloudtrail.account_id,
          aws_iam_role.loki.name
        )
      ]
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail_logs]
}
