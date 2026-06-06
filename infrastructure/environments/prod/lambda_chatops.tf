# ========================================================================
# ChatOps Alarm Lambda — Slack Notify + S3 Forensic Dump (Phase 4 Skeleton)
#   가용성 격벽: reserved_concurrent_executions = 5
#   마스터키: Secrets Manager 런타임 주입 (평문 env 금지)
# ========================================================================

# -------------------------------------------------------------------------
# 1) Slack Webhook 마스터키 — Secrets Manager (더미 JSON 플레이스홀더)
# -------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "chatops_slack_webhook" {
  name                    = "${var.env_name}-chatops-slack-webhook"
  description             = "Slack Incoming Webhook URL for alarm pipeline (runtime inject only)"
  recovery_window_in_days = 7

  tags = {
    Name        = "${var.env_name}-chatops-slack-webhook"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-slack-webhook"
  }
}

resource "aws_secretsmanager_secret_version" "chatops_slack_webhook" {
  secret_id = aws_secretsmanager_secret.chatops_slack_webhook.id
  secret_string = jsonencode({
    slack_webhook_url = "https://hooks.slack.com/services/PLACEHOLDER/PLACEHOLDER/PLACEHOLDER"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# -------------------------------------------------------------------------
# 2) Lambda 실행 Role 보강 — Secrets / Logs / VPC ENI (기존 Role 재사용)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "chatops_lambda_runtime" {
  statement {
    sid    = "AllowGetSlackWebhookSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.chatops_slack_webhook.arn,
    ]
  }

  statement {
    sid    = "AllowMultipartAbortOnChatOpsVault"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
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

  statement {
    sid    = "AllowLambdaExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:log-group:/aws/lambda/${local.alarm_pipeline_lambda_fn_name}:*",
    ]
  }

  statement {
    sid    = "AllowVpcEniForLambda"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.alarm_pipeline.name]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:Vpc"
      values   = [module.network.vpc_id]
    }
  }
}

resource "aws_iam_role_policy" "chatops_lambda_runtime" {
  name   = "${var.env_name}-chatops-lambda-runtime"
  role   = aws_iam_role.alarm_pipeline_lambda.id
  policy = data.aws_iam_policy_document.chatops_lambda_runtime.json
}

# -------------------------------------------------------------------------
# 3) Lambda VPC 격리 — Private Subnet + HTTPS egress SG
# -------------------------------------------------------------------------
resource "aws_security_group" "chatops_lambda" {
  name        = "${var.env_name}-chatops-lambda-sg"
  description = "ChatOps alarm Lambda — HTTPS egress only (Slack + AWS APIs via NAT)"
  vpc_id      = module.network.vpc_id

  egress {
    description = "HTTPS outbound (Slack webhook, Secrets Manager API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.env_name}-chatops-lambda-sg"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-lambda"
  }
}

# -------------------------------------------------------------------------
# 4) Lambda placeholder artifact (런타임 코드 추후 교체)
# -------------------------------------------------------------------------
data "archive_file" "chatops_lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.artifacts/chatops_lambda_placeholder.zip"

  source {
    content  = <<-EOF
      def handler(event, context):
          return {"statusCode": 200, "body": "chatops-alarm-lambda-placeholder"}
    EOF
    filename = "lambda_function.py"
  }
}

resource "aws_cloudwatch_log_group" "chatops_alarm_lambda" {
  name              = "/aws/lambda/${local.alarm_pipeline_lambda_fn_name}"
  retention_in_days = 14

  tags = {
    Name        = "${var.env_name}-chatops-alarm-lambda-logs"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-alarm-lambda"
  }
}

# -------------------------------------------------------------------------
# 5) Lambda 본체 — Bulkhead + VPC + Secret ARN 주입
# -------------------------------------------------------------------------
resource "aws_lambda_function" "chatops_alarm_pipeline" {
  function_name = local.alarm_pipeline_lambda_fn_name
  description   = "ChatOps alarm notifier (Slack) + forensic S3 dump — skeleton"
  role          = aws_iam_role.alarm_pipeline_lambda.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.chatops_lambda_placeholder.output_path
  source_code_hash = data.archive_file.chatops_lambda_placeholder.output_base64sha256

  reserved_concurrent_executions = 5

  vpc_config {
    subnet_ids         = module.network.private_subnets
    security_group_ids = [aws_security_group.chatops_lambda.id]
  }

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET_ARN = aws_secretsmanager_secret.chatops_slack_webhook.arn
      CHATOPS_DUMP_BUCKET_NAME = aws_s3_bucket.chatops_alarm_dump.id
    }
  }

  tags = {
    Name        = local.alarm_pipeline_lambda_fn_name
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-alarm-pipeline"
  }

  depends_on = [
    aws_iam_role_policy.chatops_lambda_runtime,
    aws_iam_role_policy.alarm_pipeline_lambda_s3_dump,
    aws_cloudwatch_log_group.chatops_alarm_lambda,
  ]
}

# -------------------------------------------------------------------------
# Outputs — Phase 5 SNS subscription wiring
# -------------------------------------------------------------------------
output "chatops_slack_webhook_secret_arn" {
  description = "Slack webhook Secrets Manager ARN (Console에서 실 URL 교체)"
  value       = aws_secretsmanager_secret.chatops_slack_webhook.arn
}

output "chatops_alarm_lambda_arn" {
  description = "ChatOps alarm Lambda ARN (SNS subscription 대상)"
  value       = aws_lambda_function.chatops_alarm_pipeline.arn
}

output "chatops_alarm_lambda_name" {
  description = "ChatOps alarm Lambda function name"
  value       = aws_lambda_function.chatops_alarm_pipeline.function_name
}
