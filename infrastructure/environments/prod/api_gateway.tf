# ========================================================================
# ChatOps JIT Auth — HTTP API Gateway (Slack Interactivity Request URL)
#   경량 HTTP API v2 + Lambda Proxy — Slack 3초 훅 대응
# ========================================================================

locals {
  chatops_jit_interactions_route = "POST /v1/chatops/slack/interactions"
}

resource "aws_apigatewayv2_api" "chatops_jit" {
  name          = "${var.env_name}-chatops-jit-api"
  protocol_type = "HTTP"
  description   = "Slack Interactivity endpoint for JIT log access auth"

  tags = {
    Name        = "${var.env_name}-chatops-jit-api"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_apigatewayv2_stage" "chatops_jit" {
  api_id      = aws_apigatewayv2_api.chatops_jit.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name        = "${var.env_name}-chatops-jit-api-stage"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-jit-auth"
  }
}

resource "aws_apigatewayv2_integration" "chatops_jit_auth" {
  api_id                 = aws_apigatewayv2_api.chatops_jit.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.chatops_jit_auth.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 3000
}

resource "aws_apigatewayv2_route" "chatops_jit_interactions" {
  api_id    = aws_apigatewayv2_api.chatops_jit.id
  route_key = local.chatops_jit_interactions_route
  target    = "integrations/${aws_apigatewayv2_integration.chatops_jit_auth.id}"
}

resource "aws_lambda_permission" "chatops_jit_auth_apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatops_jit_auth.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chatops_jit.execution_arn}/*/*"
}

# -------------------------------------------------------------------------
# Outputs — Slack App Interactivity Request URL 등록용
# -------------------------------------------------------------------------
output "chatops_jit_slack_interactivity_url" {
  description = "Slack App > Interactivity & Shortcuts > Request URL"
  value       = "${aws_apigatewayv2_api.chatops_jit.api_endpoint}${replace(local.chatops_jit_interactions_route, "POST ", "/")}"
}
