# ========================================================================
# OTel Gateway IRSA — SigV4 access to OpenSearch (traces pipeline)
# SA: monitoring/otel-gateway-opentelemetry-collector
# ========================================================================

resource "aws_iam_policy" "otel_gateway_opensearch" {
  name        = "${data.aws_ssm_parameter.eks_cluster_name.value}-otel-gateway-opensearch-policy"
  description = "Allow OTel Gateway to call OpenSearch over SigV4 (es:ESHttp*)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OpenSearchHttp"
        Effect = "Allow"
        Action = [
          "es:ESHttp*"
        ]
        Resource = [
          aws_opensearch_domain.jaeger_backend.arn,
          "${aws_opensearch_domain.jaeger_backend.arn}/*"
        ]
      }
    ]
  })
}

data "aws_iam_policy_document" "otel_gateway_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.eks_oidc_provider_arn.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:sub"
      values   = ["system:serviceaccount:monitoring:otel-gateway-opentelemetry-collector"]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "otel_gateway" {
  name               = "${data.aws_ssm_parameter.eks_cluster_name.value}-otel-gateway-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.otel_gateway_assume.json

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "otel-gateway-opensearch-sigv4"
  }
}

resource "aws_iam_role_policy_attachment" "otel_gateway_opensearch" {
  role       = aws_iam_role.otel_gateway.name
  policy_arn = aws_iam_policy.otel_gateway_opensearch.arn
}

resource "aws_ssm_parameter" "role_otel_gateway_arn" {
  name        = "${local.ssm_prefix}/eks/roles/otel-gateway-arn"
  description = "IRSA role ARN for otel-gateway OpenSearch SigV4"
  type        = "String"
  value       = aws_iam_role.otel_gateway.arn

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
  }
}

output "otel_gateway_irsa_arn" {
  description = "IRSA role ARN for otel-gateway"
  value       = aws_iam_role.otel_gateway.arn
}
