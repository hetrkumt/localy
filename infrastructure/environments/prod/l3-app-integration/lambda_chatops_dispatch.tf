# ========================================================================
# ChatOps Dispatch Lambda — SNS → Slack Block Kit + JIT Interactivity Button
#   Alertmanager Slack UI 렌더링 물리 분리 (Decoupling)
#   수신: __JIT_CTX__ 평문 (SNS Message body)
#   Zero-Trust IAM: CloudWatch Logs + Secrets Manager (Slack webhook) only
# ========================================================================

locals {
  chatops_dispatch_lambda_fn_name = "${var.env_name}-chatops-dispatch"
}

# -------------------------------------------------------------------------
# 2) Dispatch Lambda 전용 IAM Role
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
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.chatops_dispatch_lambda_fn_name}:*",
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
  name               = "${var.env_name}-chatops-dispatch-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.chatops_dispatch_lambda_assume.json

  tags = {
    Name        = "${var.env_name}-chatops-dispatch-lambda-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }
}

resource "aws_iam_role_policy" "chatops_dispatch_lambda_runtime" {
  name   = "${var.env_name}-chatops-dispatch-lambda-runtime"
  role   = aws_iam_role.chatops_dispatch_lambda.id
  policy = data.aws_iam_policy_document.chatops_dispatch_lambda_runtime.json
}

# -------------------------------------------------------------------------
# 3) Lambda artifact — Wave 4 real dispatch handler (placeholder kept for skeletons)
# -------------------------------------------------------------------------
data "archive_file" "chatops_dispatch_handler" {
  type        = "zip"
  source_file = "${path.module}/src/lambda_chatops/handler.py"
  output_path = "${path.module}/.artifacts/chatops_dispatch_handler.zip"
}

resource "aws_cloudwatch_log_group" "chatops_dispatch_lambda" {
  name              = "/aws/lambda/${local.chatops_dispatch_lambda_fn_name}"
  retention_in_days = 14

  tags = {
    Name        = "${var.env_name}-chatops-dispatch-lambda-logs"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }
}

# -------------------------------------------------------------------------
# 4) Lambda 본체 — VPC 미배치 (Slack HTTPS + Secrets Manager 공용 API)
# -------------------------------------------------------------------------
resource "aws_lambda_function" "chatops_dispatch" {
  function_name = local.chatops_dispatch_lambda_fn_name
  description   = "ChatOps dispatch — SNS (Alertmanager/ECR EventBridge) to Slack Block Kit"
  role          = aws_iam_role.chatops_dispatch_lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  # Wave 4 FinOps / Slack 429 guard — reserved concurrency needs
  # UnreservedConcurrentExecutions >= 10 after reservation. This account's
  # Concurrent executions quota is 10, so reserved=5 fails PutFunctionConcurrency.
  # Re-enable after raising L-B99A9384 (e.g. reserved_concurrent_executions = 5).
  # reserved_concurrent_executions = 5

  filename         = data.archive_file.chatops_dispatch_handler.output_path
  source_code_hash = data.archive_file.chatops_dispatch_handler.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
      ALARM_DUMP_BUCKET_NAME   = aws_s3_bucket.chatops_alarm_dump.id
    }
  }

  tags = {
    Name        = local.chatops_dispatch_lambda_fn_name
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-dispatch"
  }

  depends_on = [
    aws_iam_role_policy.chatops_dispatch_lambda_runtime,
    aws_cloudwatch_log_group.chatops_dispatch_lambda,
  ]
}

# -------------------------------------------------------------------------
# 5) SNS → Lambda 트리거 결속 (Subscription + Invoke Permission)
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
