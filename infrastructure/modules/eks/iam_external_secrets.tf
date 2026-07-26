# ========================================================================
# External Secrets Operator (ESO) IRSA Configuration
# ========================================================================

# 1. Trust Relationship Document (OIDC Federated AssumeRole)
data "aws_iam_policy_document" "eso_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    # 제로 트러스트 바인딩: 오직 external-secrets 네임스페이스의 SA만 허용
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# 2. IAM Role
resource "aws_iam_role" "eso_controller" {
  name               = "${var.cluster_name}-eso-controller-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role_policy.json
}

# 3. Least Privilege IAM Policy (Get/Describe secrets matching 'localy-*' prefix)
resource "aws_iam_policy" "eso_controller" {
  name        = "${var.cluster_name}-eso-controller-policy"
  description = "IAM Policy for External Secrets Operator with Least Privilege"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:localy-*",
          "arn:aws:secretsmanager:ap-northeast-2:${data.aws_caller_identity.current.account_id}:secret:/localy/*"
        ]
      },
      {
        Sid    = "AllowSSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/localy/*"
      }
    ]
  })
}

# 4. Attachment
resource "aws_iam_role_policy_attachment" "eso_controller" {
  role       = aws_iam_role.eso_controller.name
  policy_arn = aws_iam_policy.eso_controller.arn
}
