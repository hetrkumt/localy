provider "aws" {
  region = "ap-northeast-2"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS CMK for Terraform state encryption (Phase 0 / Architect Ruling)
# ---------------------------------------------------------------------------
resource "aws_kms_key" "terraform_state" {
  description             = "CMK for feifo-prod-tf-state-backend S3 SSE-KMS"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "terraform-state-cmk-policy"
    Statement = [
      {
        Sid    = "EnableRootAccountAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "feifo-prod-tf-state-cmk"
    Purpose = "terraform-state-encryption"
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/feifo-prod-tf-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

# 1. S3 Bucket for Terraform State
resource "aws_s3_bucket" "terraform_state" {
  bucket = "feifo-prod-tf-state-backend"

  lifecycle {
    prevent_destroy = true
  }
}

# 1-1. S3 Bucket Versioning
resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 1-2. S3 Bucket Encryption — aws:kms CMK (AES256 retired)
resource "aws_s3_bucket_server_side_encryption_configuration" "state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

# 1-3. Block Public Access
resource "aws_s3_bucket_public_access_block" "state_public_access_block" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. DynamoDB Table for State Locking (localy-terraform-lock alias name kept as existing table)
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "feifo-prod-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name    = "feifo-prod-tf-locks"
    Purpose = "terraform-state-lock"
  }
}

output "terraform_state_kms_key_arn" {
  value       = aws_kms_key.terraform_state.arn
  description = "Use as backend kms_key_id when migrating existing state backends."
}

output "terraform_state_lock_table" {
  value       = aws_dynamodb_table.terraform_locks.name
  description = "DynamoDB table name for terraform backend dynamodb_table."
}
