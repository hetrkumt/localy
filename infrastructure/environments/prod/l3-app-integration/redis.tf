# ========================================================================
# Amazon ElastiCache Redis Provisioning
# ========================================================================

# 1. Redis용 보안그룹 생성
resource "aws_security_group" "redis" {
  name        = "${var.env_name}-redis-sg"
  description = "Security Group for Redis ElastiCache"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  ingress {
    description = "Allow Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }

  ingress {
    description = "Allow Redis from EKS Pods (Secondary CIDR)"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-redis-sg" }
}

# 2. Redis Subnet Group (망 분리)
resource "aws_elasticache_subnet_group" "redis" {
  name        = "${var.env_name}-redis-subnet-group"
  subnet_ids  = split(",", data.aws_ssm_parameter.database_subnets.value)
  description = "Subnet group for Redis ElastiCache"
}

# 3. Redis Replication Group (Cluster Mode Disabled 이중화 구현)
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.env_name}-localy-redis"
  description                = "Redis Replication Group for localy application"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 2 # 1 Primary, 1 Replica
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  automatic_failover_enabled = true
  multi_az_enabled           = true

  parameter_group_name = "default.redis7"
  engine               = "redis"
  engine_version       = "7.0"
}
