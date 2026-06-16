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

# ========================================================================
# Route 53 Custom Domain & ACM SSL 결속 (api.feifo.click)
# ========================================================================
data "aws_route53_zone" "primary" {
  name         = "${var.base_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "chatops_jit_cert" {
  domain_name       = "api.${var.base_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "chatops_jit_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.chatops_jit_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

resource "aws_acm_certificate_validation" "chatops_jit_cert" {
  certificate_arn         = aws_acm_certificate.chatops_jit_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.chatops_jit_cert_validation : record.fqdn]
}

resource "aws_apigatewayv2_domain_name" "chatops_jit" {
  domain_name = "api.${var.base_domain}"

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.chatops_jit_cert.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

# 🔥 가장 중요한 결속: 새로 태어나는 API Gateway를 고정 도메인과 물리적 연결
resource "aws_apigatewayv2_api_mapping" "chatops_jit" {
  api_id      = aws_apigatewayv2_api.chatops_jit.id
  domain_name = aws_apigatewayv2_domain_name.chatops_jit.id
  stage       = aws_apigatewayv2_stage.chatops_jit.name
}

resource "aws_route53_record" "chatops_jit_api_alias" {
  name    = aws_apigatewayv2_domain_name.chatops_jit.domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.primary.zone_id

  alias {
    name                   = aws_apigatewayv2_domain_name.chatops_jit.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.chatops_jit.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# -------------------------------------------------------------------------
# Outputs — Slack App Interactivity Request URL 등록용 (고정 도메인으로 변환)
# -------------------------------------------------------------------------
output "chatops_jit_slack_interactivity_url" {
  description = "Slack App > Interactivity & Shortcuts > Request URL"
  value       = "https://${aws_apigatewayv2_domain_name.chatops_jit.domain_name}${replace(local.chatops_jit_interactions_route, "POST ", "")}"
}