# ========================================================================
# Amazon RDS PostgreSQL Provisioning
# ========================================================================
#
# Password ownership (SSOT) — item 5
# ----------------------------------
# Owner: Terraform only
#   random_password.db_password
#     ├─ aws_db_instance.rds.password
#     └─ aws_secretsmanager_secret_version.db_secret (password field)
#
# Consumers (read-only): ESO → K8s Secret → Keycloak / apps
#
# Rotate:
#   terraform apply -replace=random_password.db_password
#   (updates RDS password + SM version together; then ESO refreshes K8s)
#
# Optional token-based rotate (after wiring keepers on random_password):
#   bump var.db_master_password_rotation_token → terraform apply
# Forbidden (causes SM↔RDS drift / broken JSON):
#   - aws secretsmanager put-secret-value on localy-*-database-credentials
#   - aws rds modify-db-instance --master-user-password ...
#   - hand-editing the K8s Secret
#
# Do NOT add lifecycle.ignore_changes = [password] on the DB instance.
# That would permanently break SSOT.
# ========================================================================

# 1. RDS용 보안그룹 생성 (Pod 대역 100.64.0.0/10 허용)
resource "aws_security_group" "rds" {
  name        = "${var.env_name}-rds-sg"
  description = "Security Group for RDS PostgreSQL"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  ingress {
    description = "Allow PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }

  ingress {
    description = "Allow PostgreSQL from EKS Pods (Secondary CIDR)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-rds-sg" }
}

# 2. RDS Subnet Group (망 분리 제약: database_subnets에만 배치)
resource "aws_db_subnet_group" "rds" {
  name        = "${var.env_name}-rds-subnet-group"
  subnet_ids  = split(",", data.aws_ssm_parameter.database_subnets.value)
  description = "Database subnet group for localy RDS"
}

# 3. Master password — single source of truth
# Rotate (maintenance window): 
#   terraform apply -replace=random_password.db_password
# Optional later: add keepers = { rotation_token = var.db_master_password_rotation_token }
# (first apply after adding keepers also rotates once).
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 4. Secrets Manager — mirror of TF password (ESO reads this; never hand-edit)
resource "aws_secretsmanager_secret" "db_secret" {
  name                    = "localy-${var.env_name}-database-credentials"
  description             = "SSOT mirror of RDS master creds (owned by Terraform random_password.db_password). Do not put-secret-value manually."
  recovery_window_in_days = 0 # 즉시 삭제 가능 (실습용)

  tags = {
    Name                   = "localy-${var.env_name}-database-credentials"
    "localy.io/password-ssot" = "terraform"
    "localy.io/rotate-via"    = "terraform-apply-replace=random_password.db_password"
  }
}

resource "aws_secretsmanager_secret_version" "db_secret" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.rds.address
    port     = 5432
    username = "postgres"
    password = random_password.db_password.result
    database = "localy"
  })
}

# 5. RDS DB Instance (비용 최적화를 위해 db.t4g.micro 탑재)
#
# aws_db_instance.db_name creates exactly ONE database ("localy").
# Sibling logical DBs are GitOps Sync-hook Jobs (L3 is outside the VPC):
#   - keycloak  → platform/keycloak/base/create-db-job.yaml
#   - orderdb / paymentdb / storedb → platform/workload-dbs/base/create-dbs-job.yaml
# Do NOT add a postgresql provider here.
resource "aws_db_instance" "rds" {
  identifier                          = "${var.env_name}-localy-rds"
  allocated_storage                   = 20
  engine                              = "postgres"
  engine_version                      = "15"
  instance_class                      = "db.t4g.micro"
  db_name                             = "localy"
  username                            = "postgres"
  password                            = random_password.db_password.result
  apply_immediately                   = true # password rotation must not wait for maintenance window
  iam_database_authentication_enabled = true
  db_subnet_group_name                = aws_db_subnet_group.rds.name
  vpc_security_group_ids              = [aws_security_group.rds.id]
  skip_final_snapshot                 = true

  tags = {
    Name                      = "${var.env_name}-localy-rds"
    "localy.io/password-ssot" = "terraform"
  }
}
