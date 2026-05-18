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

  # [비용 최적화] 프로덕션이지만 비용 절감을 위해 NAT Gateway를 1개만 생성합니다. (필요시 AZ별로 확장 가능)
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS LoadBalancer 자동 프로비저닝을 위한 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  # Karpenter용 Discovery 태그를 추가합니다.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = "prod-eks" 
  }
}

# 2. VPC Endpoints 용 보안 그룹 (HTTPS 트래픽 허용)
resource "aws_security_group" "vpc_endpoints_sg" {
  name_prefix = "${var.env_name}-vpc-endpoints-sg-"
  description = "Security Group for VPC Endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # VPC 내부 트래픽만 허용
  }
}

# 3. [비용 최적화] S3 및 ECR 통신을 위한 VPC Endpoints
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.vpc_endpoints_sg.id]

  endpoints = {
    # S3 Gateway Endpoint (무료, 라우팅 테이블 기반)
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = flatten([module.vpc.private_route_table_ids, module.vpc.public_route_table_ids])
      tags            = { Name = "${var.env_name}-s3-gw-endpoint" }
    },
    # ECR API & DKR Interface Endpoints (시간당 과금되나 NAT 트래픽 비용보다 훨씬 저렴)
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
  }
}

# 모듈의 변수 정의 (같은 폴더에 variables.tf 로 분리해도 됩니다)
variable "env_name" {}
variable "vpc_cidr" {}
variable "azs" {}
variable "public_subnets" {}
variable "private_subnets" {}
variable "database_subnets" {}