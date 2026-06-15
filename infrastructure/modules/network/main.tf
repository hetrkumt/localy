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
    "kubernetes.io/role/internal-elb"                    = 1
    "kubernetes.io/cluster/${var.env_name}-eks"          = "shared"
    "karpenter.sh/discovery"                             = "${var.env_name}-eks"
  }
}

# 2. [FinOps] S3 Gateway Endpoint (무료, 라우팅 테이블 기반)
#    - ECR Interface Endpoint(ecr_api, ecr_dkr) 제거 → NAT 경유로 전환
#    - Phase 3 S3 Vault aws:sourceVpce 조건용 ID는 outputs.tf에서 노출
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = concat(
        module.vpc.private_route_table_ids,
        module.vpc.public_route_table_ids,
      )
      tags = { Name = "${var.env_name}-s3-gw-endpoint" }
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
