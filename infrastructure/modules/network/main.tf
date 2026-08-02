# 1. 사내 표준 VPC 모듈 정의
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.env_name}-vpc"
  cidr = var.vpc_cidr

  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets # Data 서브넷 분리

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.env_name}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.env_name}-eks" = "shared"
    "karpenter.sh/discovery"                    = "${var.env_name}-eks"
  }
}

# -----------------------------------------------------------------------------
# [제약사항 2] VPC CNI IP 고갈 방지 - Secondary CIDR & Pod 서브넷 구성
# -----------------------------------------------------------------------------
resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  vpc_id     = module.vpc.vpc_id
  cidr_block = var.secondary_cidr
}

resource "aws_subnet" "pod" {
  count             = length(var.azs)
  vpc_id            = aws_vpc_ipv4_cidr_block_association.secondary.vpc_id
  cidr_block        = cidrsubnet(var.secondary_cidr, 2, count.index) # 100.64.0.0/18, 100.64.64.0/18, 100.64.128.0/18
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.env_name}-pod-subnet-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.env_name}-eks" = "shared"
    "kubernetes.io/role/cni"                    = "1"
  }
}

# Pod 전용 서브넷 아웃바운드 라우팅 (NAT Gateway 연동)
resource "aws_route_table" "pod" {
  vpc_id = module.vpc.vpc_id
  tags   = { Name = "${var.env_name}-pod-rt" }
}

resource "aws_route" "pod_nat" {
  route_table_id         = aws_route_table.pod.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = module.vpc.natgw_ids[0]
}

resource "aws_route_table_association" "pod" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.pod[count.index].id
  route_table_id = aws_route_table.pod.id
}

# -----------------------------------------------------------------------------
# 2. [FinOps] ECR 및 S3 VPC Endpoints (ECR Endpoints 추가)
# -----------------------------------------------------------------------------
resource "aws_security_group" "ecr_endpoints" {
  name        = "${var.env_name}-ecr-endpoints-sg"
  description = "Shared Security Group for ECR VPC Endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr, var.secondary_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-ecr-endpoints-sg" }
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.ecr_endpoints.id]

  endpoints = {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = flatten([
        module.vpc.private_route_table_ids,
        module.vpc.public_route_table_ids,
        [aws_route_table.pod.id]
      ])
      tags = { Name = "${var.env_name}-s3-gw-endpoint" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.env_name}-ecr-api-endpoint" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      tags                = { Name = "${var.env_name}-ecr-dkr-endpoint" }
    }
  }
}

# -----------------------------------------------------------------------------
# 3. [SRE] Swarm/EKS 트래픽 전환용 공용 ALB 및 Target Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.env_name}-shared-alb-sg"
  description = "Shared ALB Security Group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-shared-alb-sg" }
}

locals {
  tg_keys = ["swarm", "eks", "user", "cart", "pay", "store"]
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.0"

  name               = "${var.env_name}-shared-alb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  target_groups = [
    {
      name_prefix      = "swarm-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "ip"
    },
    {
      name_prefix      = "eks-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "ip"
      health_check = {
        path    = "/"
        port    = "traffic-port"
        matcher = "200-399,404"
      }
    },
    {
      name_prefix      = "user-"
      backend_protocol = "HTTP"
      backend_port     = 9001
      target_type      = "ip"
      health_check = {
        path    = "/actuator/health"
        port    = "traffic-port"
        matcher = "200-399"
      }
    },
    {
      name_prefix      = "cart-"
      backend_protocol = "HTTP"
      backend_port     = 8080
      target_type      = "ip"
      health_check = {
        path    = "/actuator/health"
        port    = "traffic-port"
        matcher = "200-399"
      }
    },
    {
      name_prefix      = "pay-"
      backend_protocol = "HTTP"
      backend_port     = 8092
      target_type      = "ip"
      health_check = {
        path    = "/actuator/health/readiness"
        port    = "traffic-port"
        matcher = "200-399"
      }
    },
    {
      name_prefix      = "store-"
      backend_protocol = "HTTP"
      backend_port     = 8071
      target_type      = "ip"
      health_check = {
        path    = "/actuator/health"
        port    = "traffic-port"
        matcher = "200-399"
      }
    }
  ]
}

# -----------------------------------------------------------------------------
# 모듈 변수 정의 추가
# -----------------------------------------------------------------------------
variable "env_name" {}
variable "vpc_cidr" {}
variable "azs" {}
variable "public_subnets" {}
variable "private_subnets" {}
variable "database_subnets" {}
variable "secondary_cidr" {
  type    = string
  default = "100.64.0.0/10"
}
