# ========================================================================
# CloudTrail ??Loki Vault Data Events Precision Audit (FinOps Guarded)
# ========================================================================

data "aws_caller_identity" "cloudtrail" {}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "${module.global.env_name}-eks-cloudtrail-audit-logs"

  tags = {
    Name        = "${module.global.env_name}-eks-cloudtrail-audit-logs"
    Environment = module.global.env_name
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
  name                          = "${module.global.env_name}-loki-vault-data-events-trail"
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
    # ?뮕 [FinOps & DevSecOps] Loki S3 Data Event 怨쇨툑 諛⑹뼱???덉쇅 泥섎━
    # 
    # [諛곌꼍 諛?紐⑹쟻]
    # - Loki???쇱긽?곸씠怨?諛⑸???S3 Get/Put API ?몄텧??CloudTrail??紐⑤몢 湲곕줉??寃쎌슦 
    #   留됰????곗씠???대깽??怨쇨툑??諛쒖깮?섎?濡? Loki IRSA 沅뚰븳? 濡쒓퉭?먯꽌 ?쒖쇅??
    # 
    # [蹂댁븞 ?ш컖吏? 蹂댁셿梨?(Defense in Depth)]
    # - CloudTrail ?쒖쇅濡??명븳 蹂댁븞 ?꾪뿕? ?꾨옒???ㅼ쨷 諛⑹뼱留앹쑝濡??듭젣??
    #   1. ?몃? 諛섏텧 ?먯쿇 遊됱뇙: IAM SourceVpc 諛?S3 VPC Endpoint(VPCE) ?뺤콉?쇰줈 ?대?留????묎렐 遺덇?
    #   2. ?곗씠??蹂議?李⑤떒: S3 Object Lock (Compliance 90?? ?곸슜?쇰줈 ?щ┰???덈젅???쒖꽟?⑥뼱 諛⑹뼱
    #   3. ????덉랬 諛⑹뼱: AWS Budgets ?쒗궥 釉뚮젅?댁빱 ?곕룞?쇰줈 鍮꾩젙?곸쟻 鍮꾩슜(?몃옒?? 湲됱쬆 ??利됱떆 ?묎렐 李⑤떒
    # 
    # [TODO/Next Step]
    # - 異뷀썑 ISMS-P ???꾧꺽??而댄뵆?쇱씠?몄뒪 媛먯궗媛 ?꾩슂?댁쭏 寃쎌슦, 
    #   鍮꾩슜????댄븳 'S3 Server Access Logging'??異붽? ?쒖꽦?뷀븯?????ш컖吏?瑜??꾩쟾???댁냼?????덉쓬.
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
