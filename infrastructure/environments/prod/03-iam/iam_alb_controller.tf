
# -------------------------------------------------------------------------
# 1. AWS ??? Load Balancer Controller IAM ??? ??? ?????? (data http)
# -------------------------------------------------------------------------
data "http" "aws_lbc_iam_policy" {
  # Kubernetes SIGs??? ??? ????????? ?€???????? ???????? JSON???????? ????????
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json"
}

# -------------------------------------------------------------------------
# 2. IAM Policy ????????
# -------------------------------------------------------------------------
resource "aws_iam_policy" "aws_lbc_iam_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy-prod"
  path        = "/"
  description = "IAM policy for AWS Load Balancer Controller in prod EKS"

  # data.http????? ?€??? JSON ??????????????????
  policy = data.http.aws_lbc_iam_policy.response_body
}

# -------------------------------------------------------------------------
# 3. OIDC ??? Trust Relationship (??? ?€?? ??? ??? ???
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "aws_lbc_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    # EKS ????????OIDC ?????? ??? ???(Federated)?????
    principals {
      type        = "Federated"
      identifiers = [data.aws_ssm_parameter.oidc_provider_arn.value]
    }

    # [???] ??? ?????? ????? ??? ?€??? ??????????€ SA?????
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_ssm_parameter.oidc_issuer_url.value, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------------------
# 4. ALB ?????? ??? IAM Role ???
# -------------------------------------------------------------------------
resource "aws_iam_role" "aws_lbc_iam_role" {
  name = "AWSLoadBalancerControllerIAMRole-prod"

  # ???????????????OIDC ??? ?€???????Role?????(Assume Role Policy)?????
  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume_role_policy.json
}

# -------------------------------------------------------------------------
# 5. Role??Policy ??? (Attachment)
# -------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "aws_lbc_iam_role_attach" {
  role       = aws_iam_role.aws_lbc_iam_role.name
  policy_arn = aws_iam_policy.aws_lbc_iam_policy.arn # 1???????? ??? Policy??ARN
}

# -------------------------------------------------------------------------
# 6. Kubernetes Service Account ??? ??IAM Role ?????(IRSA ?????
# -------------------------------------------------------------------------
resource "kubernetes_service_account_v1" "aws_lbc_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lbc_iam_role.arn
    }
  }
}

