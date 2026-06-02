# ========================================================================
# Loki S3 — Customer Managed Key (CMK) for SSE-KMS & Crypto-shredding
# ========================================================================

resource "aws_kms_key" "loki_s3" {
  description             = "Loki S3 Logs Encryption Key (Supports Crypto-shredding)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

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
