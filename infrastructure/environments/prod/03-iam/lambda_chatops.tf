# ========================================================================
# ChatOps Alarm Lambda ??Slack Notify + S3 Forensic Dump (Phase 4 Skeleton)
#   媛?⑹꽦 寃⑸꼍: reserved_concurrent_executions = 5
#   留덉뒪?고궎: Secrets Manager ?고???二쇱엯 (?됰Ц env 湲덉?)
# ========================================================================

# -------------------------------------------------------------------------
# 1) Slack Webhook 留덉뒪?고궎 ??Secrets Manager (?섎룞 ?앹꽦???쒗겕由?議고쉶)
# -------------------------------------------------------------------------
# [?섏젙] 吏곸젒 ?앹꽦?섏? ?딄퀬, AWS???대? 議댁옱?섎뒗 ?쒗겕由우쓣 遺덈윭?ㅺ린留??⑸땲??
data "aws_secretsmanager_secret" "chatops_slack_webhook" {
  name = "${module.global.env_name}-chatops-slack-webhook"
}

# -------------------------------------------------------------------------
# 2) Lambda ?ㅽ뻾 Role 蹂닿컯 ??Secrets / Logs / VPC ENI (湲곗〈 Role ?ъ궗??
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "chatops_lambda_runtime" {
  statement {
    sid    = "AllowGetSlackWebhookSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      # [?섏젙] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
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
      values   = [data.aws_ssm_parameter.vpc_id.value]
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
  name   = "${module.global.env_name}-chatops-lambda-runtime"
  role   = aws_iam_role.alarm_pipeline_lambda.id
  policy = data.aws_iam_policy_document.chatops_lambda_runtime.json
}

# -------------------------------------------------------------------------
# 3) Lambda VPC 寃⑸━ ??Private Subnet + HTTPS egress SG
# -------------------------------------------------------------------------
resource "aws_security_group" "chatops_lambda" {
  name        = "${module.global.env_name}-chatops-lambda-sg"
  description = "ChatOps alarm Lambda - HTTPS egress only (Slack + AWS APIs via NAT)"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  egress {
    description = "HTTPS outbound (Slack webhook, Secrets Manager API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${module.global.env_name}-chatops-lambda-sg"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-lambda"
  }
}

# -------------------------------------------------------------------------
# 4) Lambda placeholder artifact (?고???肄붾뱶 異뷀썑 援먯껜)
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
    Name        = "${module.global.env_name}-chatops-alarm-lambda-logs"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-alarm-lambda"
  }
}

# -------------------------------------------------------------------------
# 5) Lambda 蹂몄껜 ??Bulkhead + VPC + Secret ARN 二쇱엯
# -------------------------------------------------------------------------
resource "aws_lambda_function" "chatops_alarm_pipeline" {
  function_name = local.alarm_pipeline_lambda_fn_name
  description   = "ChatOps alarm notifier (Slack) + forensic S3 dump ??skeleton"
  role          = aws_iam_role.alarm_pipeline_lambda.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.chatops_lambda_placeholder.output_path
  source_code_hash = data.archive_file.chatops_lambda_placeholder.output_base64sha256

  # ?썳截?[SRE 媛?쒕젅?? 濡쒓렇 ??깂 諛⑹???寃⑸꼍 (AWS 怨꾩젙 ?쒕룄 ?곹뼢 ???쒖꽦???덉젙)
  # reserved_concurrent_executions = 5

  vpc_config {
    subnet_ids         = jsondecode(data.aws_ssm_parameter.private_subnet_ids.value)
    security_group_ids = [aws_security_group.chatops_lambda.id]
  }

  environment {
    variables = {
      # [?섏젙] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
      SLACK_WEBHOOK_SECRET_ARN = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
      CHATOPS_DUMP_BUCKET_NAME = aws_s3_bucket.chatops_alarm_dump.id
    }
  }

  tags = {
    Name        = local.alarm_pipeline_lambda_fn_name
    Environment = module.global.env_name
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
# Outputs ??Phase 5 SNS subscription wiring
# -------------------------------------------------------------------------
output "chatops_slack_webhook_secret_arn" {
  description = "Slack webhook Secrets Manager ARN"
  # [?섏젙] aws_secretsmanager_secret -> data.aws_secretsmanager_secret
  value = data.aws_secretsmanager_secret.chatops_slack_webhook.arn
}

output "chatops_alarm_lambda_arn" {
  description = "ChatOps alarm Lambda ARN (SNS subscription ???"
  value       = aws_lambda_function.chatops_alarm_pipeline.arn
}

output "chatops_alarm_lambda_name" {
  description = "ChatOps alarm Lambda function name"
  value       = aws_lambda_function.chatops_alarm_pipeline.function_name
}

# ========================================================================
# ChatOps JIT Auth Lambda ??Slack Interactivity ?좎썝 寃利?(Phase 2)
#   VPC 誘몃같移???ENI cold start ?쒓굅, Slack 3珥??????# ========================================================================

locals {
  chatops_jit_auth_lambda_fn_name = "${module.global.env_name}-chatops-jit-auth"
}

# -------------------------------------------------------------------------
# Slack Signing Secret ??Secrets Manager (?섎룞 ?앹꽦 ?쒗겕由?議고쉶)
# -------------------------------------------------------------------------
data "aws_secretsmanager_secret" "chatops_slack_signing" {
  name = "${module.global.env_name}-chatops-slack-signing-secret"
}

# -------------------------------------------------------------------------
# JIT Auth ?꾩슜 IAM Role (湲곗〈 alarm_pipeline_lambda Role怨?遺꾨━)
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

  statement {
    sid    = "AllowKMSCryptoForForensicVault"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [
      aws_kms_key.chatops_s3.arn,
    ]
  }
}

resource "aws_iam_role" "chatops_jit_auth_lambda" {
  name               = "${module.global.env_name}-chatops-jit-auth-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.chatops_jit_auth_lambda_assume.json

  tags = {
    Name        = "${module.global.env_name}-chatops-jit-auth-lambda-role"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_iam_role_policy" "chatops_jit_auth_lambda_runtime" {
  name   = "${module.global.env_name}-chatops-jit-auth-lambda-runtime"
  role   = aws_iam_role.chatops_jit_auth_lambda.id
  policy = data.aws_iam_policy_document.chatops_jit_auth_lambda_runtime.json
}

# -------------------------------------------------------------------------
# Lambda artifact ??蹂꾨룄 .py ?뚯씪 (?ν썑 CI/CD ?꾪솚 ?⑹씠)
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
    Name        = "${module.global.env_name}-chatops-jit-auth-lambda-logs"
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_lambda_function" "chatops_jit_auth" {
  function_name = local.chatops_jit_auth_lambda_fn_name
  description   = "Slack Interactivity JIT auth ??SRE whitelist gate for request_jit_log_access"
  role          = aws_iam_role.chatops_jit_auth_lambda.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  timeout       = 30
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
    Environment = module.global.env_name
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
