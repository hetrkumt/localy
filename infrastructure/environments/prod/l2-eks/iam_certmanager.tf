# 🛡️ Phase 1: Cert-Manager IAM Role 및 ServiceAccount 구성

data "aws_route53_zone" "prod_zone" {
  name         = "feifo.click." # 지휘관님의 실제 도메인 (끝에 마침표 필수)
  private_zone = false
}

# 1. Cert-Manager를 위한 최소 권한 IAM Policy (Route 53 DNS-01 Challenge 용도)
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

# 2. OIDC 기반 Assume Role Policy 문서 생성 (제로 트러스트)
data "aws_iam_policy_document" "prod_certmanager_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test = "StringEquals"
      # [핫픽스 1] OIDC sub 변수 끝의 불필요한 공백 제거
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      # 오직 cert-manager 네임스페이스의 cert-manager SA만 접근 가능
      values = ["system:serviceaccount:cert-manager:cert-manager"]
    }

    condition {
      test = "StringEquals"
      # [핫픽스 1] OIDC aud 변수 끝의 불필요한 공백 제거
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

# 3. Cert-Manager 전용 IAM Role 생성
resource "aws_iam_role" "prod_certmanager_irsa_role" {
  name               = "prod-certmanager-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.prod_certmanager_assume_role_policy.json
}

# 4. Role과 Policy 결속
resource "aws_iam_role_policy_attachment" "prod_certmanager_policy_attach" {
  role       = aws_iam_role.prod_certmanager_irsa_role.name
  policy_arn = aws_iam_policy.prod_certmanager_route53_policy.arn
}
