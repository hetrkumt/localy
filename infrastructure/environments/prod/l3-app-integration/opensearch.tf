# ========================================================================
# Amazon OpenSearch Provisioning for Jaeger Backend
# ========================================================================

# 1. OpenSearch 방화벽 (EKS 파드에서 오는 443 포트만 허용)
resource "aws_security_group" "opensearch" {
  name        = "${var.env_name}-opensearch-sg"
  description = "Security Group for OpenSearch (Jaeger Backend)"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  ingress {
    description = "Allow HTTPS from EKS Pods"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10", data.aws_vpc.existing.cidr_block]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. OpenSearch KMS Key for Encryption at Rest
resource "aws_kms_key" "opensearch" {
  description             = "KMS key for Jaeger OpenSearch"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# 3. OpenSearch 클러스터 본체 (3대 고가용성 구성)
resource "aws_opensearch_domain" "jaeger_backend" {
  domain_name    = "${var.env_name}-jaeger-backend"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = "m6g.large.search"
    instance_count         = 3
    zone_awareness_enabled = true
    zone_awareness_config {
      availability_zone_count = 3
    }
  }

  vpc_options {
    subnet_ids         = slice(split(",", data.aws_ssm_parameter.private_subnets.value), 0, 3)
    security_group_ids = [aws_security_group.opensearch.id]
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 50
  }

  encrypt_at_rest { 
    enabled    = true 
    kms_key_id = aws_kms_key.opensearch.arn
  }
  node_to_node_encryption { enabled = true }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = "es:ESHttp*"
        Resource = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${var.env_name}-jaeger-backend/*"
      }
    ]
  })
}
