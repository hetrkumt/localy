# =============================================================================
# Interface VPC Endpoints — SNS + STS (Alertmanager IRSA / L4 Zero-Trust)
# =============================================================================
# SNS Publish + STS AssumeRoleWithWebIdentity must stay on private AWS network.
# Shared SG: Ingress TCP 443 from VPC CIDR only (0.0.0.0/0 denied).
# ENIs span all private subnets (3-AZ).
# =============================================================================

data "aws_region" "interface_vpc_endpoint" {}

# ---------------------------------------------------------------------------
# Shared Security Group — Interface VPCE ENI ingress lockdown
# ---------------------------------------------------------------------------
resource "aws_security_group" "interface_vpc_endpoint" {
  name        = "${var.env_name}-interface-vpce-sg"
  description = "Interface VPC Endpoint ENI - HTTPS from VPC CIDR only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name        = "${var.env_name}-interface-vpce-sg"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "sns-sts-interface-vpce"
  }
}

resource "aws_security_group_rule" "interface_vpc_endpoint_ingress_https" {
  type              = "ingress"
  description       = "HTTPS from VPC CIDR only"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.interface_vpc_endpoint.id
}

resource "aws_security_group_rule" "interface_vpc_endpoint_egress_all" {
  type              = "egress"
  description       = "Allow ENI return traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.interface_vpc_endpoint.id
}

# ---------------------------------------------------------------------------
# SNS Interface VPC Endpoint
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "sns" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.interface_vpc_endpoint.name}.sns"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.interface_vpc_endpoint.id]

  tags = {
    Name        = "${var.env_name}-sns-interface-endpoint"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-sns"
  }
}

# ---------------------------------------------------------------------------
# STS Interface VPC Endpoint — IRSA token exchange (NAT bypass prevention)
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.interface_vpc_endpoint.name}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.interface_vpc_endpoint.id]

  tags = {
    Name        = "${var.env_name}-sts-interface-endpoint"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "irsa-sts"
  }
}
