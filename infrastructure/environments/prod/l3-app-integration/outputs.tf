output "loki_bucket_name" {
  description = "The name of the Loki logs S3 bucket"
  value       = aws_s3_bucket.loki_logs.id
}

output "loki_key_arn" {
  description = "The KMS key ARN for Loki logs S3 bucket"
  value       = aws_kms_key.loki_s3.arn
}

output "chatops_topic_arn" {
  description = "The ChatOps SNS Topic ARN"
  value       = aws_sns_topic.chatops_alarm_pipeline.arn
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "MSK Bootstrap Brokers for IAM Authentication"
  value       = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
}

output "msk_bootstrap_brokers_plaintext" {
  description = "MSK Bootstrap Brokers for Plaintext Connection"
  value       = aws_msk_cluster.msk.bootstrap_brokers
}

# ========================================================================
# Store Service Outputs
# ========================================================================

output "store_bucket_name" {
  description = "The name of the store-service images S3 bucket"
  value       = aws_s3_bucket.store_images.id
}

output "store_key_arn" {
  description = "The KMS key ARN for store-service S3 bucket"
  value       = aws_kms_key.store_s3.arn
}

output "store_role_arn" {
  description = "The IAM Role ARN for store-service Pod Identity"
  value       = aws_iam_role.store_service.arn
}
