# ========================================================================
# Loki S3 — Customer Managed Key (CMK) for SSE-KMS & Crypto-shredding
# ========================================================================

data "aws_region" "current" {}

data "aws_caller_identity" "loki_kms" {}

resource "aws_kms_key" "loki_s3" {
  description             = "Loki S3 Logs Encryption Key (Supports Crypto-shredding)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "loki-s3-encryption-key-policy"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.loki_kms.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowLokiIRSACrypto"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.loki.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3ViaServiceForLokiVault"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${data.aws_region.current.name}.amazonaws.com"
          }
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.loki_logs.arn
          }
        }
      },
    ]
  })

  tags = {
    Name        = "${var.env_name}-loki-s3-kms"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-s3-encryption"
  }
}

resource "aws_kms_alias" "loki_s3" {
  name          = "alias/${var.env_name}-loki-s3-key"
  target_key_id = aws_kms_key.loki_s3.key_id
}