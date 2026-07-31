# ========================================================================
# Platform Secrets Manager paths for External Secrets Operator
# SSOT: Terraform (random_password)
# Paths match GitOps ExternalSecrets under /localy/${env}/platform/*
# Do not hand-edit via put-secret-value or sm-migrate-oauth-grafana.ps1.
# ========================================================================

locals {
  platform_sm_prefix = "/localy/${var.env_name}/platform"
}

resource "random_password" "grafana_admin_password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "platform_grafana" {
  name                    = "${local.platform_sm_prefix}/grafana"
  description             = "Grafana admin credentials (SSOT: terraform random_password.grafana_admin_password)"
  recovery_window_in_days = 0

  tags = {
    Name                      = "${local.platform_sm_prefix}/grafana"
    "localy.io/password-ssot" = "terraform"
    "localy.io/service"       = "grafana"
  }
}

resource "aws_secretsmanager_secret_version" "platform_grafana" {
  secret_id = aws_secretsmanager_secret.platform_grafana.id
  secret_string = jsonencode({
    admin-user     = "admin"
    admin-password = random_password.grafana_admin_password.result
  })
}
