# -------------------------------------------------------------------------
# ExternalDNS IRSA 구성 (1단계): AWS Route53 레코드 조작 권한 최소화
# -------------------------------------------------------------------------
# OIDC/클러스터 정보는 동일 state의 module.eks output을 사용합니다 (prod-eks).
# data "aws_eks_cluster" 조회는 greenfield apply 시 'couldn't find resource'를 유발합니다.
# -------------------------------------------------------------------------

# 1. ExternalDNS가 AWS Route53에 접근할 수 있는 최소 권한 Policy 정의

data "aws_route53_zone" "externaldns_zone" {
  name         = "${var.base_domain}."
  private_zone = false
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid    = "AllowListHostedZones"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowListResourceRecordSets"
    effect = "Allow"
    actions = [
      "route53:ListResourceRecordSets"
    ]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.externaldns_zone.zone_id}"]
  }

  statement {
    sid    = "AllowChangeResourceRecordSets"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.externaldns_zone.zone_id}"]
  }
}

module "irsa_externaldns" {
  source = "../../modules/irsa"

  role_name           = "prod-externaldns-irsa-role"
  namespace           = "kube-system"
  serviceaccount_name = "external-dns-sa"
  oidc_provider_arn   = module.eks.oidc_provider_arn
  oidc_provider_url   = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  custom_policy_json  = data.aws_iam_policy_document.external_dns.json
}

# 5. Kubernetes Service Account 생성 및 IAM Role 바인딩
resource "kubernetes_service_account_v1" "external_dns_sa" {
  depends_on = [
    module.eks,
    module.irsa_externaldns,
  ]

  metadata {
    name      = "external-dns-sa"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_externaldns.iam_role_arn
    }
  }
}
