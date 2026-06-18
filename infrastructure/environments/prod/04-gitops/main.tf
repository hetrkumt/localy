# ========================================================================
# Layer 04 — GitOps Bridge Data Hub (SSM 우체통 소비자)
# ========================================================================
# terraform_remote_state 사용 금지.
# EKS/네트워크 정보는 02-compute가 발행한 SSM Parameter만 읽습니다.
# ========================================================================

# --- Layer 02 Compute SSM Import (아키텍트 팀 확정 경로) ---

data "aws_ssm_parameter" "cluster_name" {
  name = "/localy/prod/compute/cluster_name"
}

data "aws_ssm_parameter" "eks_endpoint" {
  name = "/localy/prod/compute/eks_endpoint"
}

data "aws_ssm_parameter" "eks_ca" {
  name = "/localy/prod/compute/eks_ca"
}

data "aws_ssm_parameter" "oidc_issuer_url" {
  name = "/localy/prod/compute/oidc_issuer_url"
}

data "aws_ssm_parameter" "oidc_provider_arn" {
  name = "/localy/prod/compute/oidc_provider_arn"
}

# --- ALB Ingress 연동 (WAF 화이트리스트 + ACM) ---

data "aws_wafv2_web_acl" "ingress_waf" {
  name  = "prod-ingress-waf"
  scope = "REGIONAL"
}

data "aws_acm_certificate" "prod_cert" {
  domain      = module.global.base_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

# --- SSM → Layer 04 로컬 변수 매핑 ---

locals {
  cluster_name      = data.aws_ssm_parameter.cluster_name.value
  eks_endpoint      = data.aws_ssm_parameter.eks_endpoint.value
  eks_ca            = data.aws_ssm_parameter.eks_ca.value
  oidc_issuer_url   = data.aws_ssm_parameter.oidc_issuer_url.value
  oidc_provider_arn = data.aws_ssm_parameter.oidc_provider_arn.value

  # IAM OIDC condition key = host/path only (no https:// scheme).
  oidc_provider_url = trimprefix(local.oidc_issuer_url, "https://")

  argocd_host = "argocd.${module.global.base_domain}"
  argocd_url  = "https://${local.argocd_host}"

  eso_namespace            = "external-secrets"
  eso_service_account_name = "external-secrets"
}

# ========================================================================
# ESO — IAM 최소권한 족쇄 (IRSA)
# ========================================================================
# Resource "*" 엄격 금지 → prod/* prefix Secrets Manager only
# ========================================================================

data "aws_iam_policy_document" "eso_secretsmanager" {
  statement {
    sid    = "AllowReadProdNamespaceSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:ap-northeast-2:*:secret:prod/*",
    ]
  }
}

module "irsa_eso" {
  source = "../../../modules/irsa"

  role_name           = "prod-eso-irsa-role"
  namespace           = local.eso_namespace
  serviceaccount_name = local.eso_service_account_name
  oidc_provider_arn   = local.oidc_provider_arn
  oidc_provider_url   = local.oidc_provider_url
  custom_policy_json  = data.aws_iam_policy_document.eso_secretsmanager.json
}

# ========================================================================
# ESO — Helm Engine
# ========================================================================

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.5"
  namespace        = local.eso_namespace
  create_namespace = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_eso.iam_role_arn
  }

  depends_on = [
    module.irsa_eso,
  ]
}

# ========================================================================
# ArgoCD — Helm Engine (ALB + WAF + OIDC SSO 뼈대)
# ========================================================================
# 금지: root-application.yaml 등 App of Apps 매니페스트 Terraform 배포
#       → GitOps 오토-싱크 선행 실행 방지, bootstrap/는 ArgoCD UI/CLI로 후속 등록
# ========================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.10"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

  values = [<<-EOT
global:
  domain: ${local.argocd_host}

server:
  ingress:
    enabled: true
    ingressClassName: alb
    hostname: ${local.argocd_host}
    annotations:
      kubernetes.io/ingress.class: alb
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/group.name: prod-ingress-group
      alb.ingress.kubernetes.io/group.order: "20"
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/wafv2-acl-arn: ${data.aws_wafv2_web_acl.ingress_waf.arn}
      alb.ingress.kubernetes.io/certificate-arn: ${data.aws_acm_certificate.prod_cert.arn}
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"

configs:
  cm:
    url: ${local.argocd_url}
    oidc.config: |
      name: Corporate SSO
      issuer: PLACEHOLDER_OIDC_ISSUER_URL
      clientID: PLACEHOLDER_OIDC_CLIENT_ID
      clientSecret: $oidc.corporate-sso.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
      requestedIDTokenClaims:
        groups:
          essential: true
  params:
    server.insecure: "true"
EOT
  ]
}
