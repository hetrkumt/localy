# ========================================================================
# Legacy Loki KMS keys — Object Lock ciphertext still encrypted with prior CMKs
# ========================================================================
# Preserve set (teardown.ps1): Object Lock bucket + every CMK that still
# encrypts locked object versions + IRSA principal rebind on apply.
#
# New writes use aws_kms_key.loki_s3. Orphan keys from prior teardowns are
# listed here (and in gitignored loki-preserve-set.auto.tfvars when generated).
#
# SSOT for AllowLokiIRSACrypto: current L2 IRSA ARN (not stale AROA RoleId).
# Set loki_legacy_kms_key_ids = [] after retention expiry + object gone.
# ========================================================================

variable "loki_legacy_kms_key_ids" {
  description = "Prior Loki S3 CMK ids still required for Object-Lock objects. Empty skips management."
  type        = list(string)
  default     = ["c4e097ff-d777-4c9b-9098-e3d467a15f95"]
}

data "aws_kms_key" "loki_legacy" {
  for_each = toset(var.loki_legacy_kms_key_ids)
  key_id   = each.value
}

resource "aws_kms_key_policy" "loki_legacy" {
  for_each = data.aws_kms_key.loki_legacy
  key_id   = each.value.id

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
