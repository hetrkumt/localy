# ========================================================================
# ChatOps Dispatch Lambda ??SNS ??Slack Block Kit + JIT Interactivity Button
#   Alertmanager Slack UI ?뚮뜑留?臾쇰━ 遺꾨━ (Decoupling)
#   ?섏떊: __JIT_CTX__ ?됰Ц (SNS Message body)
#   Zero-Trust IAM: CloudWatch Logs + Secrets Manager (Slack webhook) only
# ========================================================================

locals {
  chatops_dispatch_lambda_fn_name = "${module.global.env_name}-chatops-dispatch"
}

# -------------------------------------------------------------------------
# 1) Slack Webhook Secret ??湲곗〈 data source ?ъ궗??(lambda_chatops.tf)
# -------------------------------------------------------------------------

# -------------------------------------------------------------------------
# 2) Dispatch Lambda ?꾩슜 IAM Role (alarm_pipeline_lambda Role怨?遺꾨━)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "chatops_dispatch_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "chatops_dispatch_lambda_runtime" {
  statement {
    sid    = "AllowGetSlackWebhookSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      data.aws_secretsmanager_secret.chatops_slack_webhook.arn,
    ]
  }

  statement {
    sid    = "AllowDispatchExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:log-group:/aws/lambda/${local.chatops_dispatch_lambda_fn_name}:*",
    ]
  }

  statement {
    sid    = "AllowForensicDumpPutObject"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.chatops_alarm_dump.arn}/forensic/*",
    ]
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

resource "aws_iam_role" "chatops_dispatch_lambda" {
  name               = "${module.global.env_name}-chatops-dispatch-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.chatops_dispatch_lambda_assume.json

  tags = {
    Name        = "${module.global.env_name}-chatops-dispatch-lambda-role"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }
}

resource "aws_iam_role_policy" "chatops_dispatch_lambda_runtime" {
  name   = "${module.global.env_name}-chatops-dispatch-lambda-runtime"
  role   = aws_iam_role.chatops_dispatch_lambda.id
  policy = data.aws_iam_policy_document.chatops_dispatch_lambda_runtime.json
}

# -------------------------------------------------------------------------
# 3) Lambda artifact ??chatops-dispatch/ ?붾젆?곕━ zip (JIT Auth ?⑦꽩 ?뺤옣)
# -------------------------------------------------------------------------
data "archive_file" "chatops_dispatch_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/chatops-dispatch"
  output_path = "${path.module}/.artifacts/chatops_dispatch_lambda.zip"
}

resource "aws_cloudwatch_log_group" "chatops_dispatch_lambda" {
  name              = "/aws/lambda/${local.chatops_dispatch_lambda_fn_name}"
  retention_in_days = 14

  tags = {
    Name        = "${module.global.env_name}-chatops-dispatch-lambda-logs"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }
}

# -------------------------------------------------------------------------
# 4) Lambda 蹂몄껜 ??VPC 誘몃같移?(Slack HTTPS + Secrets Manager 怨듭슜 API)
# -------------------------------------------------------------------------
resource "aws_lambda_function" "chatops_dispatch" {
  function_name = local.chatops_dispatch_lambda_fn_name
  description   = "ChatOps dispatch ??SNS __JIT_CTX__ to Slack Block Kit + JIT button"
  role          = aws_iam_role.chatops_dispatch_lambda.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.chatops_dispatch_lambda.output_path
  source_code_hash = data.archive_file.chatops_dispatch_lambda.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
      ALARM_DUMP_BUCKET_NAME   = aws_s3_bucket.chatops_alarm_dump.id
    }
  }

  tags = {
    Name        = local.chatops_dispatch_lambda_fn_name
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }

  depends_on = [
    aws_iam_role_policy.chatops_dispatch_lambda_runtime,
    aws_cloudwatch_log_group.chatops_dispatch_lambda,
  ]
}

# -------------------------------------------------------------------------
# 5) SNS ??Lambda ?몃━嫄?寃곗냽 (Subscription + Invoke Permission)
#    Note: SNS??Event Source Mapping???꾨땶 Subscription ?⑦꽩 ?ъ슜
# -------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "chatops_dispatch" {
  topic_arn = aws_sns_topic.chatops_alarm_pipeline.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chatops_dispatch.arn
}

resource "aws_lambda_permission" "chatops_dispatch_sns" {
  statement_id  = "AllowExecutionFromChatOpsAlarmPipelineSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatops_dispatch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.chatops_alarm_pipeline.arn
}

# -------------------------------------------------------------------------
# Outputs
# -------------------------------------------------------------------------
output "chatops_dispatch_lambda_arn" {
  description = "ChatOps dispatch Lambda ARN"
  value       = aws_lambda_function.chatops_dispatch.arn
}

output "chatops_dispatch_lambda_name" {
  description = "ChatOps dispatch Lambda function name"
  value       = aws_lambda_function.chatops_dispatch.function_name
}

output "chatops_dispatch_lambda_role_arn" {
  description = "ChatOps dispatch Lambda execution Role ARN"
  value       = aws_iam_role.chatops_dispatch_lambda.arn
}
