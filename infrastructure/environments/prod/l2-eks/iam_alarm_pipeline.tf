# ========================================================================
# Alarm Pipeline IAM — SNS Publisher Role
# ========================================================================

data "aws_caller_identity" "alarm_pipeline" {}

data "aws_region" "alarm_pipeline" {}

locals {
  # Phase 4에서 동일 이름으로 생성될 리소스 — ARN 선반영 (budgets Deny 스코핑용)
  alarm_pipeline_sns_topic_name = "${var.env_name}-alarm-pipeline-chatops-topic"
  alarm_pipeline_sns_topic_arn  = "arn:aws:sns:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:${local.alarm_pipeline_sns_topic_name}"

  # [Phase 4] Alertmanager K8s 신원·마스터키 명칭 (OIDC / RBAC / Helm 단일 소스)
  alarm_pipeline_alertmanager_sa_name = "alarm-pipeline-sns-publisher"
}

# -------------------------------------------------------------------------
# SNS Publisher Role — Alertmanager IRSA (Helm SA 결속: helm_kube_prometheus.tf)
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
      values   = ["system:serviceaccount:monitoring:${local.alarm_pipeline_alertmanager_sa_name}"]
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
# Outputs
# -------------------------------------------------------------------------
output "alarm_pipeline_sns_role_arn" {
  description = "Alertmanager SNS publisher IRSA Role ARN"
  value       = aws_iam_role.alarm_pipeline_sns.arn
}

output "alarm_pipeline_sns_topic_arn_expected" {
  description = "Phase 4 SNS Topic must use this name for budgets Deny alignment"
  value       = local.alarm_pipeline_sns_topic_arn
}
