
# -------------------------------------------------------------------------
# 1. AWS 공식 Load Balancer Controller IAM 정책 원본 다운로드 (data http)
# -------------------------------------------------------------------------
data "http" "aws_lbc_iam_policy" {
  # Kubernetes SIGs에서 공식 유지보수하는 가장 안정적인 버전의 정책 JSON을 동적으로 호출합니다.
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json"
}

# -------------------------------------------------------------------------
# 2. IAM Policy 리소스 생성
# -------------------------------------------------------------------------
resource "aws_iam_policy" "aws_lbc_iam_policy" {
  name        = "AWSLoadBalancerControllerIAMPolicy-prod"
  path        = "/"
  description = "IAM policy for AWS Load Balancer Controller in prod EKS"
  
  # data.http를 통해 가져온 JSON 바디를 그대로 주입합니다.
  policy      = data.http.aws_lbc_iam_policy.response_body
}

# -------------------------------------------------------------------------
# 3. OIDC 기반 Trust Relationship (신뢰 관계) 정책 문서 정의
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "aws_lbc_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    # EKS 클러스터의 OIDC 공급자를 인증 주체(Federated)로 선언
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn] 
    }

    # [핵심] 제로 트러스트 바인딩: 오직 지정된 네임스페이스와 SA만 허용
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------------------
# 4. ALB 컨트롤러 전용 IAM Role 생성
# -------------------------------------------------------------------------
resource "aws_iam_role" "aws_lbc_iam_role" {
  name               = "AWSLoadBalancerControllerIAMRole-prod"
  
  # 위에서 정의한 깐깐한 OIDC 신뢰 관계 문서를 Role의 입구(Assume Role Policy)에 장착
  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume_role_policy.json
}

# -------------------------------------------------------------------------
# 5. Role과 Policy 결합 (Attachment)
# -------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "aws_lbc_iam_role_attach" {
  role       = aws_iam_role.aws_lbc_iam_role.name
  policy_arn = aws_iam_policy.aws_lbc_iam_policy.arn # 1차 구현에서 만든 Policy의 ARN
}

# -------------------------------------------------------------------------
# 6. Kubernetes Service Account 생성 및 IAM Role 바인딩 (IRSA 피날레)
# -------------------------------------------------------------------------
resource "kubernetes_service_account_v1" "aws_lbc_sa" {
  depends_on = [module.eks]

  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    
    # [핵심] AWS IAM Role과 K8s Service Account를 물리적으로 엮어주는 차원 관문
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lbc_iam_role.arn
    }
  }
}

