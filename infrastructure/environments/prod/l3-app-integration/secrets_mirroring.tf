# ========================================================================
# Secrets Mirroring for External Secrets Operator (Secrets Manager <-> SSM Parameter Store)
# ========================================================================

# 1. MSK Bootstrap Servers Secret
resource "aws_secretsmanager_secret" "msk_bootstrap_servers" {
  name                    = local.ssm_paths["msk_bootstrap_servers"]
  recovery_window_in_days = 0 # allows instant destroy/recreate for dev
}

resource "aws_secretsmanager_secret_version" "msk_bootstrap_servers" {
  secret_id     = aws_secretsmanager_secret.msk_bootstrap_servers.id
  secret_string = aws_ssm_parameter.msk_bootstrap_servers.value
}

# 2. Store Service S3 Images Bucket Name Secret
resource "aws_secretsmanager_secret" "store_bucket_name" {
  name                    = local.ssm_paths["store_bucket_name"]
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "store_bucket_name" {
  secret_id     = aws_secretsmanager_secret.store_bucket_name.id
  secret_string = aws_ssm_parameter.store_bucket_name.value
}

# 3. Store Service S3 Encryption KMS Key ARN Secret
resource "aws_secretsmanager_secret" "store_key_arn" {
  name                    = local.ssm_paths["store_key_arn"]
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "store_key_arn" {
  secret_id     = aws_secretsmanager_secret.store_key_arn.id
  secret_string = aws_ssm_parameter.store_key_arn.value
}

# 4. Store Service Pod Identity IAM Role ARN Secret
resource "aws_secretsmanager_secret" "store_role_arn" {
  name                    = local.ssm_paths["store_role_arn"]
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "store_role_arn" {
  secret_id     = aws_secretsmanager_secret.store_role_arn.id
  secret_string = aws_ssm_parameter.store_role_arn.value
}

# 5. Keycloak Credentials Secret (Dummy secret template for user-service)
resource "aws_secretsmanager_secret" "user_keycloak_credentials" {
  name                    = "localy-prod-user-keycloak-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "user_keycloak_credentials" {
  secret_id = aws_secretsmanager_secret.user_keycloak_credentials.id
  secret_string = jsonencode({
    # Must match Keycloak realm client "user-service" secret (realm-import.json)
    clientSecret = "7f9a1b2c-3d4e-5f6a-7b8c-9d0e1f2a3b4c"
  })
}
