# ========================================================================
# Legacy Loki KMS key — Object Lock objects still encrypted with pre-rebuild CMK
# ========================================================================
# Teardown leaves s3://prod-eks-loki-logs-vault (COMPLIANCE) and may schedule
# deletion of the previous CMK. After rebuild, new writes use aws_kms_key.loki_s3
# but old objects still need this key for Decrypt.
#
# SSOT for AllowLokiIRSACrypto: current L2 IRSA ARN (not stale AROA RoleId).
# Set loki_legacy_kms_key_id = "" after retention expiry + object re-encrypt/delete.
# ========================================================================

variable "loki_legacy_kms_key_id" {
  description = "Pre-rebuild Loki S3 CMK id still required for Object-Lock objects. Empty skips management."
  type        = string
  default     = "c4e097ff-d777-4c9b-9098-e3d467a15f95"
}

data "aws_kms_key" "loki_legacy" {
  count  = var.loki_legacy_kms_key_id != "" ? 1 : 0
  key_id = var.loki_legacy_kms_key_id
}

resource "aws_kms_key_policy" "loki_legacy" {
  count  = var.loki_legacy_kms_key_id != "" ? 1 : 0
  key_id = data.aws_kms_key.loki_legacy[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "loki-s3-legacy-encryption-key-policy"
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
        Sid    = "AllowLokiIRSACrypto"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_ssm_parameter.role_loki_arn.value
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
}
