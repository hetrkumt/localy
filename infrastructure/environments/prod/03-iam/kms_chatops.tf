# ========================================================================
# ChatOps S3 ??Customer Managed Key (CMK) for SSE-KMS & Crypto-shredding
# ========================================================================

data "aws_caller_identity" "chatops_kms" {}

resource "aws_kms_key" "chatops_s3" {
  description             = "ChatOps Alarm Forensic Vault S3 Encryption Key (Supports Crypto-shredding)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "chatops-s3-encryption-key-policy"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.chatops_kms.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowChatOpsLambdaCrypto"
        Effect = "Allow"
        Principal = {
          AWS = [
            aws_iam_role.alarm_pipeline_lambda.arn,
            aws_iam_role.chatops_dispatch_lambda.arn,
            aws_iam_role.chatops_jit_auth_lambda.arn,
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3ViaServiceForChatOpsVault"
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
            "aws:SourceArn" = aws_s3_bucket.chatops_alarm_dump.arn
          }
        }
      },
    ]
  })

  tags = {
    Name        = "${module.global.env_name}-chatops-s3-kms"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-s3-encryption"
  }
}

resource "aws_kms_alias" "chatops_s3" {
  name          = "alias/${module.global.env_name}-chatops-s3-key"
  target_key_id = aws_kms_key.chatops_s3.key_id
}
