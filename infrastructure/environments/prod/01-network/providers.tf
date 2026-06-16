terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

module "global" {
  source = "../../../modules/global_config"
}

provider "aws" {
  region = module.global.region

  default_tags {
    tags = merge(module.global.common_tags, {
      TerraformLayer = "01-network"
    })
  }
}
