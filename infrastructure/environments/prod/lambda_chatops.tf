# ========================================================================
# ChatOps Alarm Lambda — Slack Notify + S3 Forensic Dump (Phase 4 Skeleton)
#   가용성 격벽: reserved_concurrent_executions = 5
#   마스터키: Secrets Manager 런타임 주입 (평문 env 금지)
# ========================================================================

# -------------------------------------------------------------------------
# 1) Slack Webhook 마스터키 — Secrets Manager (수동 생성된 시크릿 조회)
# -------------------------------------------------------------------------
# [수정] 직접 생성하지 않고, AWS에 이미 존재하는 시크릿을 불러오기만 합니다.
data "aws_secretsmanager_secret" "chatops_slack_webhook" {
  name = "${var.env_name}-chatops-slack-webhook"
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
      # [수정] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
      data.aws_secretsmanager_secret.chatops_slack_webhook.arn,
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
  description = "ChatOps alarm Lambda - HTTPS egress only (Slack + AWS APIs via NAT)"
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

  # 🛡️ [SRE 가드레일] 로그 폭탄 방지용 격벽 (AWS 계정 한도 상향 후 활성화 예정)
  # reserved_concurrent_executions = 5

  vpc_config {
    subnet_ids         = module.network.private_subnets
    security_group_ids = [aws_security_group.chatops_lambda.id]
  }

  environment {
    variables = {
      # [수정] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
      SLACK_WEBHOOK_SECRET_ARN = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
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
  description = "Slack webhook Secrets Manager ARN"
  # [수정] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
  value = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
}

output "chatops_alarm_lambda_arn" {
  description = "ChatOps alarm Lambda ARN (SNS subscription 대상)"
  value       = aws_lambda_function.chatops_alarm_pipeline.arn
}

output "chatops_alarm_lambda_name" {
  description = "ChatOps alarm Lambda function name"
  value       = aws_lambda_function.chatops_alarm_pipeline.function_name
}

# ========================================================================
# ChatOps JIT Auth Lambda — Slack Interactivity 신원 검증 (Phase 2)
#   VPC 미배치 — ENI cold start 제거, Slack 3초 훅 대응
# ========================================================================

locals {
  chatops_jit_auth_lambda_fn_name = "${var.env_name}-chatops-jit-auth"
}

# -------------------------------------------------------------------------
# Slack Signing Secret — Secrets Manager (수동 생성 시크릿 조회)
# -------------------------------------------------------------------------
data "aws_secretsmanager_secret" "chatops_slack_signing" {
  name = "${var.env_name}-chatops-slack-signing-secret"
}

# -------------------------------------------------------------------------
# JIT Auth 전용 IAM Role (기존 alarm_pipeline_lambda Role과 분리)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "chatops_jit_auth_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "chatops_jit_auth_lambda_runtime" {
  statement {
    sid    = "AllowGetSlackSigningSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      data.aws_secretsmanager_secret.chatops_slack_signing.arn,
    ]
  }

  statement {
    sid    = "AllowPresignGetObjectOnForensicVault"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.chatops_alarm_dump.arn,
      "${aws_s3_bucket.chatops_alarm_dump.arn}/forensic/*",
    ]
  }

  statement {
    sid    = "AllowJitAuthExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.alarm_pipeline.name}:${data.aws_caller_identity.alarm_pipeline.account_id}:log-group:/aws/lambda/${local.chatops_jit_auth_lambda_fn_name}:*",
    ]
  }
}

resource "aws_iam_role" "chatops_jit_auth_lambda" {
  name               = "${var.env_name}-chatops-jit-auth-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.chatops_jit_auth_lambda_assume.json

  tags = {
    Name        = "${var.env_name}-chatops-jit-auth-lambda-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_iam_role_policy" "chatops_jit_auth_lambda_runtime" {
  name   = "${var.env_name}-chatops-jit-auth-lambda-runtime"
  role   = aws_iam_role.chatops_jit_auth_lambda.id
  policy = data.aws_iam_policy_document.chatops_jit_auth_lambda_runtime.json
}

# -------------------------------------------------------------------------
# Lambda artifact — 별도 .py 파일 (향후 CI/CD 전환 용이)
# -------------------------------------------------------------------------
data "archive_file" "chatops_jit_auth_lambda" {
  type        = "zip"
  output_path = "${path.module}/.artifacts/chatops_jit_auth_lambda.zip"
  source_file = "${path.module}/chatops-jit-auth/lambda_function.py"
}

resource "aws_cloudwatch_log_group" "chatops_jit_auth_lambda" {
  name              = "/aws/lambda/${local.chatops_jit_auth_lambda_fn_name}"
  retention_in_days = 14

  tags = {
    Name        = "${var.env_name}-chatops-jit-auth-lambda-logs"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_lambda_function" "chatops_jit_auth" {
  function_name = local.chatops_jit_auth_lambda_fn_name
  description   = "Slack Interactivity JIT auth — SRE whitelist gate for request_jit_log_access"
  role          = aws_iam_role.chatops_jit_auth_lambda.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 3
  memory_size   = 128

  filename         = data.archive_file.chatops_jit_auth_lambda.output_path
  source_code_hash = data.archive_file.chatops_jit_auth_lambda.output_base64sha256

  environment {
    variables = {
      SLACK_SIGNING_SECRET_ARN     = data.aws_secretsmanager_secret.chatops_slack_signing.arn
      SRE_SLACK_USER_IDS           = join(",", var.chatops_sre_slack_user_ids)
      REQUIRE_SLACK_SIGNATURE      = "true"
      CHATOPS_DUMP_BUCKET_NAME     = aws_s3_bucket.chatops_alarm_dump.id
      PRESIGNED_URL_EXPIRY_SECONDS = "900"
    }
  }

  tags = {
    Name        = local.chatops_jit_auth_lambda_fn_name
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }

  depends_on = [
    aws_iam_role_policy.chatops_jit_auth_lambda_runtime,
    aws_cloudwatch_log_group.chatops_jit_auth_lambda,
  ]
}

output "chatops_jit_auth_lambda_arn" {
  description = "JIT auth Lambda ARN"
  value       = aws_lambda_function.chatops_jit_auth.arn
}

output "chatops_jit_auth_lambda_name" {
  description = "JIT auth Lambda function name"
  value       = aws_lambda_function.chatops_jit_auth.function_name
}