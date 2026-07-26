# ========================================================================
# Keycloak Admin Credentials Provisioning
# ========================================================================

# 1. Keycloak 초기 Admin 비밀번호 동적 생성
resource "random_password" "keycloak_admin_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 2. AWS Secrets Manager에 Keycloak 최고 관리자(Admin) 자격증명 저장
resource "aws_secretsmanager_secret" "keycloak_admin" {
  name                    = "localy-${var.env_name}-keycloak-admin"
  description             = "Initial Admin credentials for Keycloak (Used by ESO)"
  recovery_window_in_days = 0 # 실습 편의를 위해 즉시 삭제 가능하도록 설정
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.keycloak_admin_password.result
  })
}
