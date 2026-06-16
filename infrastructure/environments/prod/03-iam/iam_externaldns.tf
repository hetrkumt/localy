# -------------------------------------------------------------------------
# ExternalDNS IRSA ??? (1???): AWS Route53 ???????? ??? ?????# -------------------------------------------------------------------------
# OIDC/?????? ???????? state??module.eks output??????????(prod-eks).
# data "aws_eks_cluster" ?????greenfield apply ??'couldn't find resource'??????????
# -------------------------------------------------------------------------

# 1. ExternalDNS?€ AWS Route53???????????? ??? ??? Policy ???

data "aws_route53_zone" "externaldns_zone" {
  name         = "${module.global.base_domain}."
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
  source = "../../../modules/irsa"

  role_name           = "prod-externaldns-irsa-role"
  namespace           = "kube-system"
  serviceaccount_name = "external-dns-sa"
  oidc_provider_arn   = data.aws_ssm_parameter.oidc_provider_arn.value
  oidc_provider_url   = replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")
  custom_policy_json  = data.aws_iam_policy_document.external_dns.json
}

# 5. Kubernetes Service Account ?? ? IAM Role ???
resource "kubernetes_service_account_v1" "external_dns_sa" {
  depends_on = [
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
