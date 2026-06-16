# --------------------------------------------------------
# [2단계] 네트워크(VPC) 모듈 호출
# --------------------------------------------------------
module "network" {
  source = "../../../modules/network"

  env_name         = module.global.env_name
  cluster_name     = module.global.cluster_name
  vpc_cidr         = var.vpc_cidr_block
  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets
}
