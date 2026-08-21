# ========================================================================
# Argo CD Notifications ESO IRSA — read Slack webhook from Secrets Manager
# SA: argocd/argocd-notifications-eso-sa
# ========================================================================

data "aws_secretsmanager_secret" "argocd_notifications_slack_webhook" {
  name = "${var.env_name}-chatops-slack-webhook"
}

data "aws_iam_policy_document" "argocd_notifications_eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.eks_oidc_provider_arn.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:sub"
      values = [
        "system:serviceaccount:argocd:argocd-notifications-eso-sa",
      ]
    }
  }
}

data "aws_iam_policy_document" "argocd_notifications_eso_sm" {
  statement {
    sid    = "ReadChatopsSlackWebhook"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      data.aws_secretsmanager_secret.argocd_notifications_slack_webhook.arn,
    ]
  }
}

resource "aws_iam_role" "argocd_notifications_eso" {
  name               = "${data.aws_ssm_parameter.eks_cluster_name.value}-argocd-notifications-eso-role"
  assume_role_policy = data.aws_iam_policy_document.argocd_notifications_eso_assume.json

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "argocd-notifications-eso-slack"
  }
}

resource "aws_iam_role_policy" "argocd_notifications_eso_sm" {
  name   = "${data.aws_ssm_parameter.eks_cluster_name.value}-argocd-notifications-eso-sm"
  role   = aws_iam_role.argocd_notifications_eso.id
  policy = data.aws_iam_policy_document.argocd_notifications_eso_sm.json
}

resource "aws_ssm_parameter" "role_argocd_notifications_eso_arn" {
  name        = "${local.ssm_prefix}/eks/roles/argocd-notifications-eso-arn"
  description = "IRSA role ARN for Argo CD Notifications ESO Slack webhook"
  type        = "String"
  value       = aws_iam_role.argocd_notifications_eso.arn

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
  }
}

output "argocd_notifications_eso_irsa_arn" {
  description = "IRSA role ARN for argocd-notifications-eso-sa"
  value       = aws_iam_role.argocd_notifications_eso.arn
}
