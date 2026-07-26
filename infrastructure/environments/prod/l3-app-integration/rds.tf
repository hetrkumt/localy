# ========================================================================
# Amazon RDS PostgreSQL Provisioning
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

# 3. random_password를 통한 마스터 비밀번호 동적 생성
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 4. AWS Secrets Manager에 시크릿 생성 및 마스터 패스워드 매립
resource "aws_secretsmanager_secret" "db_secret" {
  name                    = "localy-${var.env_name}-database-credentials"
  description             = "Database credentials for localy application"
  recovery_window_in_days = 0 # 즉시 삭제 가능 (실습용)
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
resource "aws_db_instance" "rds" {
  identifier             = "${var.env_name}-localy-rds"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t4g.micro"
  db_name                = "localy"
  username               = "postgres"
  password               = random_password.db_password.result
  iam_database_authentication_enabled = true
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
}
