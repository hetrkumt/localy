# ========================================================================
# Alarm Pipeline IAM — SNS Publisher + S3 Dumper Lambda Roles
#   Concrete Fix: budgets.tf placeholder 제거 + Phase 4 ARN 선반영
# ========================================================================

data "aws_caller_identity" "alarm_pipeline" {}

data "aws_region" "alarm_pipeline" {}

locals {
  # Phase 4에서 동일 이름으로 생성될 리소스 — ARN 선반영 (budgets Deny 스코핑용)
  alarm_pipeline_sns_topic_name = "${var.env_name}-alarm-pipeline-chatops-topic"
  alarm_pipeline_lambda_fn_name = "${var.env_name}-alarm-pipeline-s3-dumper"

  alarm_pipeline_sns_topic_arn = "arn:aws:sns:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:${local.alarm_pipeline_sns_topic_name}"
  alarm_pipeline_lambda_fn_arn   = "arn:aws:lambda:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:function:${local.alarm_pipeline_lambda_fn_name}"
}

# -------------------------------------------------------------------------
# SNS Publisher Role — Alertmanager IRSA (Phase 4 Helm SA 결속 예정)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "alarm_pipeline_sns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:monitoring:alarm-pipeline-sns-publisher"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "alarm_pipeline_sns_publish" {
  statement {
    sid    = "AllowPublishAlarmPipelineTopicOnly"
    effect = "Allow"
    actions = [
      "sns:Publish",
    ]
    resources = [
      local.alarm_pipeline_sns_topic_arn,
    ]
  }
}

resource "aws_iam_role" "alarm_pipeline_sns" {
  name               = "${var.env_name}-k8s-alarm-pipeline-sns-role"
  assume_role_policy = data.aws_iam_policy_document.alarm_pipeline_sns_assume.json

  tags = {
    Name        = "${var.env_name}-k8s-alarm-pipeline-sns-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-sns"
  }
}

resource "aws_iam_role_policy" "alarm_pipeline_sns_publish" {
  name   = "${var.env_name}-alarm-pipeline-sns-publish"
  role   = aws_iam_role.alarm_pipeline_sns.id
  policy = data.aws_iam_policy_document.alarm_pipeline_sns_publish.json
}

# -------------------------------------------------------------------------
# S3 Dumper Lambda Role — chatops vault PutObject only (SourceVpc lock)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "alarm_pipeline_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "alarm_pipeline_lambda_s3_dump" {
  statement {
    sid    = "AllowPutObjectOnChatOpsVaultOnly"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.chatops_alarm_dump.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpc"
      values   = [module.network.vpc_id]
    }
  }
}

resource "aws_iam_role" "alarm_pipeline_lambda" {
  name               = "${var.env_name}-k8s-alarm-pipeline-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.alarm_pipeline_lambda_assume.json

  tags = {
    Name        = "${var.env_name}-k8s-alarm-pipeline-lambda-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-lambda"
  }
}

resource "aws_iam_role_policy" "alarm_pipeline_lambda_s3_dump" {
  name   = "${var.env_name}-alarm-pipeline-lambda-s3-dump"
  role   = aws_iam_role.alarm_pipeline_lambda.id
  policy = data.aws_iam_policy_document.alarm_pipeline_lambda_s3_dump.json
}

# -------------------------------------------------------------------------
# Outputs — Phase 4 Helm/Lambda/SNS wiring
# -------------------------------------------------------------------------
output "alarm_pipeline_sns_role_arn" {
  description = "Alertmanager SNS publisher IRSA Role ARN"
  value       = aws_iam_role.alarm_pipeline_sns.arn
}

output "alarm_pipeline_lambda_role_arn" {
  description = "Alarm S3 dumper Lambda execution Role ARN"
  value       = aws_iam_role.alarm_pipeline_lambda.arn
}

output "alarm_pipeline_sns_topic_arn_expected" {
  description = "Phase 4 SNS Topic must use this name for budgets Deny alignment"
  value       = local.alarm_pipeline_sns_topic_arn
}

output "alarm_pipeline_lambda_fn_arn_expected" {
  description = "Phase 4 Lambda must use this name for budgets Deny alignment"
  value       = local.alarm_pipeline_lambda_fn_arn
}
