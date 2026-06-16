# ????Phase 1: Cert-Manager IAM Role ??ServiceAccount ???

data "aws_route53_zone" "prod_zone" {
  name         = "${module.global.base_domain}." # ???????? ??? ?????(??? ????????)
  private_zone = false
}

# 1. Cert-Manager????? ??? ??? IAM Policy (Route 53 DNS-01 Challenge ???)
resource "aws_iam_policy" "prod_certmanager_route53_policy" {
  name        = "prod-certmanager-route53-policy"
  description = "Least privilege Route53 policy for Cert-Manager DNS-01 challenges"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.prod_zone.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      }
    ]
  })
}

# 2. OIDC ??? Assume Role Policy ??? ??? (??? ??????)
data "aws_iam_policy_document" "prod_certmanager_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:sub"
      values   = ["system:serviceaccount:cert-manager:cert-manager"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [data.aws_ssm_parameter.oidc_provider_arn.value]
      type        = "Federated"
    }
  }
}

# 3. Cert-Manager ??? IAM Role ???
resource "aws_iam_role" "prod_certmanager_irsa_role" {
  name               = "prod-certmanager-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.prod_certmanager_assume_role_policy.json
}

# 4. Role??Policy ???
resource "aws_iam_role_policy_attachment" "prod_certmanager_policy_attach" {
  role       = aws_iam_role.prod_certmanager_irsa_role.name
  policy_arn = aws_iam_policy.prod_certmanager_route53_policy.arn
}

# 5. Cert-Manager ????????? ??? ??? (EKS ?????? ????????)
resource "kubernetes_namespace_v1" "cert_manager_ns" {
  metadata {
    name = "cert-manager"
  }
}

# 6. ????????ServiceAccount(????? ??? ??IAM Role ???
resource "kubernetes_service_account_v1" "cert_manager_sa" {
  metadata {
    name      = "cert-manager"
    namespace = kubernetes_namespace_v1.cert_manager_ns.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.prod_certmanager_irsa_role.arn
    }
  }
  automount_service_account_token = true

  # AWS ??? ??? ??????????? ????????????SA ??? ??? (?????????????)
  depends_on = [
    kubernetes_namespace_v1.cert_manager_ns,
    aws_iam_role_policy_attachment.prod_certmanager_policy_attach
  ]
}
