# ========================================================================
# Alarm Pipeline IAM ??SNS Publisher + S3 Dumper Lambda Roles
#   Concrete Fix: budgets.tf placeholder ?쒓굅 + Phase 4 ARN ?좊컲??# ========================================================================

data "aws_caller_identity" "alarm_pipeline" {}

data "aws_region" "alarm_pipeline" {}

locals {
  # Phase 4?먯꽌 ?숈씪 ?대쫫?쇰줈 ?앹꽦??由ъ냼????ARN ?좊컲??(budgets Deny ?ㅼ퐫?묒슜)
  alarm_pipeline_sns_topic_name = "${module.global.env_name}-alarm-pipeline-chatops-topic"
  alarm_pipeline_lambda_fn_name = "${module.global.env_name}-alarm-pipeline-s3-dumper"

  alarm_pipeline_sns_topic_arn = "arn:aws:sns:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:${local.alarm_pipeline_sns_topic_name}"
  alarm_pipeline_lambda_fn_arn = "arn:aws:lambda:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:function:${local.alarm_pipeline_lambda_fn_name}"

  # [Phase 4] Alertmanager K8s ?좎썝쨌留덉뒪?고궎 紐낆묶 (OIDC / RBAC / Helm ?⑥씪 ?뚯뒪)
  alarm_pipeline_alertmanager_sa_name         = "alarm-pipeline-sns-publisher"
  alarm_pipeline_alertmanager_k8s_secret_name = "alarm-pipeline-alertmanager-secrets"
}

# -------------------------------------------------------------------------
# SNS Publisher Role ??Alertmanager IRSA (Helm SA 寃곗냽: helm_kube_prometheus.tf)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "alarm_pipeline_sns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.oidc_provider_arn.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:sub"
      values   = ["system:serviceaccount:monitoring:${local.alarm_pipeline_alertmanager_sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:aud"
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
  name               = "${module.global.env_name}-k8s-alarm-pipeline-sns-role"
  assume_role_policy = data.aws_iam_policy_document.alarm_pipeline_sns_assume.json

  tags = {
    Name        = "${module.global.env_name}-k8s-alarm-pipeline-sns-role"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-sns"
  }
}

resource "aws_iam_role_policy" "alarm_pipeline_sns_publish" {
  name   = "${module.global.env_name}-alarm-pipeline-sns-publish"
  role   = aws_iam_role.alarm_pipeline_sns.id
  policy = data.aws_iam_policy_document.alarm_pipeline_sns_publish.json
}

# -------------------------------------------------------------------------
# S3 Dumper Lambda Role ??chatops vault PutObject only (SourceVpc lock)
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
      values   = [data.aws_ssm_parameter.vpc_id.value]
    }
  }

  statement {
    sid    = "AllowKMSCryptoForForensicVault"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [
      aws_kms_key.chatops_s3.arn,
    ]
  }
}

resource "aws_iam_role" "alarm_pipeline_lambda" {
  name               = "${module.global.env_name}-k8s-alarm-pipeline-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.alarm_pipeline_lambda_assume.json

  tags = {
    Name        = "${module.global.env_name}-k8s-alarm-pipeline-lambda-role"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-lambda"
  }
}

resource "aws_iam_role_policy" "alarm_pipeline_lambda_s3_dump" {
  name   = "${module.global.env_name}-alarm-pipeline-lambda-s3-dump"
  role   = aws_iam_role.alarm_pipeline_lambda.id
  policy = data.aws_iam_policy_document.alarm_pipeline_lambda_s3_dump.json
}

# -------------------------------------------------------------------------
# Outputs ??Phase 4 Helm/Lambda/SNS wiring
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

# -------------------------------------------------------------------------
# Alertmanager Pinpoint RBAC ??SM ?곕룞 Secret get/watch ?꾩슜 (Intent)
# Phase 4.5: Helm ClusterRole resourceNames ?ㅼ퐫???⑥튂 ?덉젙
# -------------------------------------------------------------------------
resource "kubernetes_role_v1" "alarm_pipeline_alertmanager_secret_reader" {
  metadata {
    name      = "alarm-pipeline-alertmanager-secret-reader"
    namespace = "monitoring"

    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "rbac"
      "managed-by"                  = "terraform"
    }
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "watch"]
    resource_names = [
      local.alarm_pipeline_alertmanager_k8s_secret_name,
    ]
  }
}

resource "kubernetes_role_binding_v1" "alarm_pipeline_alertmanager_secret_reader" {
  metadata {
    name      = "alarm-pipeline-alertmanager-secret-reader"
    namespace = "monitoring"

    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "rbac"
      "managed-by"                  = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.alarm_pipeline_alertmanager_secret_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.alarm_pipeline_alertmanager_sa_name
    namespace = "monitoring"
  }

  depends_on = [
    kubernetes_namespace_v1.monitoring,
  ]
}
