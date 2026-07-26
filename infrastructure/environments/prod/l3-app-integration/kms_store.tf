# ========================================================================
# Store S3 — Customer Managed Key (CMK) for SSE-KMS
# ========================================================================

resource "aws_kms_key" "store_s3" {
  description             = "Store-service S3 Images Encryption Key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "store-s3-encryption-key-policy"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowS3ViaServiceForStoreImages"
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
        }
      },
    ]
  })

  tags = {
    Name        = "${var.env_name}-store-s3-kms"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "store-s3-encryption"
  }
}

resource "aws_kms_alias" "store_s3" {
  name          = "alias/${var.env_name}-store-s3-key"
  target_key_id = aws_kms_key.store_s3.key_id
}
