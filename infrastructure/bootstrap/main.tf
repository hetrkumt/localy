provider "aws" {
  region = "ap-northeast-2"
}

# 1. S3 Bucket for Terraform State
resource "aws_s3_bucket" "terraform_state" {
  bucket = "feifo-prod-tf-state-backend" 

  lifecycle {
    prevent_destroy = true
  }
}

# 1-1. S3 Bucket Versioning (버전 관리)
resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 1-2. S3 Bucket Encryption (서버 측 암호화)
resource "aws_s3_bucket_server_side_encryption_configuration" "state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 1-3. Block Public Access (퍼블릭 액세스 차단)
resource "aws_s3_bucket_public_access_block" "state_public_access_block" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. DynamoDB Table for State Locking
resource "aws_dynamodb_table" "terraform_locks" {
  # DynamoDB 이름도 동일하게 맞춰주는 것이 관리하기 좋습니다.
  name         = "feifo-prod-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}