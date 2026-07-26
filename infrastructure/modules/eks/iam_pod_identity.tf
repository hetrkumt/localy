# ========================================================================
# EKS Pod Identity Workload IAM Role (차세대 권한 연동 체계)
# ========================================================================

# 1. Trust Relationship Document (EKS Pod Identity Service Principal)
data "aws_iam_policy_document" "pod_identity_assume_role_policy" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# 2. Workload용 공통 깡통 IAM Role (향후 l3-app-integration 등에서 Policy를 바인딩하여 확장)
resource "aws_iam_role" "workload_pod_identity" {
  name               = "${var.cluster_name}-workload-pod-identity-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role_policy.json

  tags = {
    Name      = "${var.cluster_name}-workload-pod-identity-role"
    Purpose   = "workload-eks-pod-identity"
    ManagedBy = "terraform"
  }
}
