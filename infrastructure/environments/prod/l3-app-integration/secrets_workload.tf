# ========================================================================
# Workload Secrets Manager paths for External Secrets Operator
# SSOT: Terraform (RDS password, MSK, S3/KMS, oauth random_password)
# Paths match GitOps ExternalSecrets under /localy/${env}/workload/*
# Do not hand-edit via put-secret-value or sm-seed-workload-secrets.ps1.
# ========================================================================

locals {
  workload_sm_prefix = "/localy/${var.env_name}/workload"
}

# --- OAuth client secrets (apps: user-oauth / edge-oauth) -----------------
# Reuse existing user random; add edge. After first apply (or secret rotate),
# align Keycloak clients: infrastructure/scripts/keycloak-align-oauth.ps1

resource "random_password" "edge_oauth_client_secret" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "workload_user_oauth" {
  name                    = "${local.workload_sm_prefix}/user-oauth"
  description             = "user-service Keycloak client secret (SSOT: terraform random_password.user_keycloak_client_secret)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/user-oauth"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "user-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_user_oauth" {
  secret_id = aws_secretsmanager_secret.workload_user_oauth.id
  secret_string = jsonencode({
    clientSecret = random_password.user_keycloak_client_secret.result
  })
}

resource "aws_secretsmanager_secret" "workload_edge_oauth" {
  name                    = "${local.workload_sm_prefix}/edge-oauth"
  description             = "edge-service Keycloak client secret (SSOT: terraform random_password.edge_oauth_client_secret)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/edge-oauth"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "edge-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_edge_oauth" {
  secret_id = aws_secretsmanager_secret.workload_edge_oauth.id
  secret_string = jsonencode({
    clientSecret = random_password.edge_oauth_client_secret.result
  })
}

# Keep legacy localy-prod-user-keycloak-credentials (secrets_mirroring.tf) on the
# same random_password.user_keycloak_client_secret as workload_user_oauth.

# --- order / payment DB+MSK ----------------------------------------------

resource "aws_secretsmanager_secret" "workload_order_db" {
  name                    = "${local.workload_sm_prefix}/order-db"
  description             = "order-service RDS+MSK connection (SSOT: terraform RDS + MSK)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/order-db"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "order-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_order_db" {
  secret_id = aws_secretsmanager_secret.workload_order_db.id
  secret_string = jsonencode({
    host                  = aws_db_instance.rds.address
    port                  = tostring(aws_db_instance.rds.port)
    username              = aws_db_instance.rds.username
    password              = random_password.db_password.result
    msk_bootstrap_servers = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
  })
}

resource "aws_secretsmanager_secret" "workload_payment_db" {
  name                    = "${local.workload_sm_prefix}/payment-db"
  description             = "payment-service RDS+MSK connection (SSOT: terraform RDS + MSK)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/payment-db"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "payment-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_payment_db" {
  secret_id = aws_secretsmanager_secret.workload_payment_db.id
  secret_string = jsonencode({
    host                  = aws_db_instance.rds.address
    port                  = tostring(aws_db_instance.rds.port)
    username              = aws_db_instance.rds.username
    password              = random_password.db_password.result
    msk_bootstrap_servers = aws_msk_cluster.msk.bootstrap_brokers_sasl_iam
  })
}

# --- store DB+S3+KMS -----------------------------------------------------

resource "aws_secretsmanager_secret" "workload_store_db" {
  name                    = "${local.workload_sm_prefix}/store-db"
  description             = "store-service RDS+S3+KMS (SSOT: terraform RDS + S3 + KMS)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/store-db"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "store-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_store_db" {
  secret_id = aws_secretsmanager_secret.workload_store_db.id
  secret_string = jsonencode({
    username       = aws_db_instance.rds.username
    password       = random_password.db_password.result
    s3_bucket_name = aws_s3_bucket.store_images.bucket
    kms_key_arn    = aws_kms_key.store_s3.arn
  })
}

# --- cart Redis (AuthTokenEnabled=false → empty password) ----------------

resource "aws_secretsmanager_secret" "workload_cart_redis" {
  name                    = "${local.workload_sm_prefix}/cart-redis"
  description             = "cart-service Redis password (empty when ElastiCache auth disabled)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.workload_sm_prefix}/cart-redis"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "cart-service"
  }
}

resource "aws_secretsmanager_secret_version" "workload_cart_redis" {
  secret_id = aws_secretsmanager_secret.workload_cart_redis.id
  secret_string = jsonencode({
    password = ""
  })
}
