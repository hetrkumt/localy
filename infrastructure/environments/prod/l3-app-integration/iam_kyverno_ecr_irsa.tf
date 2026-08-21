# ========================================================================
# Kyverno ECR IRSA — Cosign verifyImages must pull account ECR manifests
# SAs: kyverno/{admission,background,reports}-controller
# ========================================================================

data "aws_iam_policy_document" "kyverno_ecr_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.eks_oidc_provider_arn.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${data.aws_ssm_parameter.eks_oidc_provider.value}:sub"
      values = [
        "system:serviceaccount:kyverno:kyverno-admission-controller",
        "system:serviceaccount:kyverno:kyverno-background-controller",
        "system:serviceaccount:kyverno:kyverno-reports-controller",
      ]
    }
  }
}

resource "aws_iam_role" "kyverno_ecr" {
  name               = "${data.aws_ssm_parameter.eks_cluster_name.value}-kyverno-ecr-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.kyverno_ecr_assume.json

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "kyverno-cosign-ecr-pull"
  }
}

resource "aws_iam_role_policy_attachment" "kyverno_ecr_readonly" {
  role       = aws_iam_role.kyverno_ecr.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_ssm_parameter" "role_kyverno_ecr_arn" {
  name        = "${local.ssm_prefix}/eks/roles/kyverno-ecr-arn"
  description = "IRSA role ARN for Kyverno Cosign ECR pull"
  type        = "String"
  value       = aws_iam_role.kyverno_ecr.arn

  tags = {
    Environment = var.env_name
    ManagedBy   = "terraform"
  }
}

output "kyverno_ecr_irsa_arn" {
  description = "IRSA role ARN for Kyverno ECR/Cosign verify"
  value       = aws_iam_role.kyverno_ecr.arn
}
