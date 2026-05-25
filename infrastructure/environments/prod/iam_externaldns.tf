# -------------------------------------------------------------------------
# ExternalDNS IRSA 구성 (1단계): AWS Route53 레코드 조작 권한 최소화
# -------------------------------------------------------------------------
# OIDC/클러스터 정보는 동일 state의 module.eks output을 사용합니다 (prod-eks).
# data "aws_eks_cluster" 조회는 greenfield apply 시 'couldn't find resource'를 유발합니다.
# -------------------------------------------------------------------------

# 1. ExternalDNS가 AWS Route53에 접근할 수 있는 최소 권한 Policy 정의
resource "aws_iam_policy" "prod_externaldns_route53_policy" {
  name        = "prod-externaldns-route53-policy"
  path        = "/"
  description = "Least privilege Route53 policy for ExternalDNS in prod"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListHostedZones"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowListResourceRecordSets"
        Effect = "Allow"
        Action = [
          "route53:ListResourceRecordSets"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowChangeResourceRecordSets"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/*"
      }
    ]
  })
}

# 2. OIDC Trust Relationship: 오직 kube-system/external-dns-sa만 Role Assume 가능
data "aws_iam_policy_document" "prod_externaldns_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# 3. ExternalDNS IRSA 전용 IAM Role 생성
resource "aws_iam_role" "prod_externaldns_irsa_role" {
  name               = "prod-externaldns-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.prod_externaldns_assume_role_policy.json
}

# 4. IAM Role에 최소 권한 Policy 결합
resource "aws_iam_role_policy_attachment" "prod_externaldns_policy_attach" {
  role       = aws_iam_role.prod_externaldns_irsa_role.name
  policy_arn = aws_iam_policy.prod_externaldns_route53_policy.arn
}

# 5. Kubernetes Service Account 생성 및 IAM Role 바인딩
resource "kubernetes_service_account_v1" "external_dns_sa" {
  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.prod_externaldns_policy_attach,
  ]

  metadata {
    name      = "external-dns-sa"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.prod_externaldns_irsa_role.arn
    }
  }
}
