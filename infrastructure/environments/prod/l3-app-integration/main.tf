terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket = "feifo-prod-tf-state-backend"
    key    = "eks-gitops/prod/l3-app-integration.tfstate"
    region = "ap-northeast-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# --- AWS SSM Parameters (L1/L2 간접 참조용 배관) ---

data "aws_ssm_parameter" "vpc_id" {
  name = local.ssm_paths["vpc_id"]
}

data "aws_ssm_parameter" "private_subnets" {
  name = local.ssm_paths["private_subnets"]
}

# 보수반영: RDS/Redis 생성을 위한 database_subnets 매핑
data "aws_ssm_parameter" "database_subnets" {
  name = local.ssm_paths["database_subnets"]
}

data "aws_ssm_parameter" "s3_vpc_endpoint_id" {
  name = local.ssm_paths["s3_vpc_endpoint_id"]
}

data "aws_ssm_parameter" "eks_cluster_name" {
  name = local.ssm_paths["eks_cluster_name"]
}

data "aws_ssm_parameter" "eks_oidc_provider" {
  name = local.ssm_paths["eks_oidc_provider"]
}

data "aws_ssm_parameter" "eks_oidc_provider_arn" {
  name = local.ssm_paths["eks_oidc_provider_arn"]
}

# --- IRSA Role ARNs (L2에서 생성 완료) ---

data "aws_ssm_parameter" "role_loki_arn" {
  name = local.ssm_paths["role_loki_arn"]
}

data "aws_ssm_parameter" "role_alarm_pipeline_sns_arn" {
  name = local.ssm_paths["role_alarm_pipeline_sns_arn"]
}

# 2차 타격: EKS 공통 깡통 Role ARN 불러오기 (권한 바인딩용)
data "aws_ssm_parameter" "role_workload_pod_identity_arn" {
  name = local.ssm_paths["role_workload_pod_identity_arn"]
}

# 보수반영: VPC CIDR block을 동적으로 탐색하여 보안그룹에 Ingress 맵핑
data "aws_vpc" "existing" {
  id = data.aws_ssm_parameter.vpc_id.value
}

# --- 공통 로컬 변수 정의 (locals 중복 선언 충돌 차단) ---
locals {
  alarm_pipeline_sns_topic_name = "${var.env_name}-alarm-pipeline-chatops-topic"
  alarm_pipeline_lambda_fn_name = "${var.env_name}-alarm-pipeline-s3-dumper"

  alarm_pipeline_sns_topic_arn = "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.alarm_pipeline_sns_topic_name}"
  alarm_pipeline_lambda_fn_arn = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.alarm_pipeline_lambda_fn_name}"

  s3_policy_bypass_principal_arns = distinct(compact(concat(
    var.s3_bucket_policy_bypass_principal_arns,
    [
      data.aws_iam_session_context.current.issuer_arn,
      data.aws_caller_identity.current.arn,
    ],
  )))
}

# --- 공통 데이터 소스 ---
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}
