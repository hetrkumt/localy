# ========================================================================
# Workload Pod Identity Associations (user, payment, cart)
# ========================================================================

resource "aws_eks_pod_identity_association" "user_service" {
  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = "user-service"
  service_account = "user-service-sa"
  role_arn        = data.aws_ssm_parameter.role_workload_pod_identity_arn.value
}

resource "aws_eks_pod_identity_association" "payment_service" {
  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = "payment-service"
  service_account = "payment-service-sa"
  role_arn        = data.aws_ssm_parameter.role_workload_pod_identity_arn.value
}

resource "aws_eks_pod_identity_association" "cart_service" {
  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = "cart-service"
  service_account = "cart-service-sa"
  role_arn        = data.aws_ssm_parameter.role_workload_pod_identity_arn.value
}

# store_service association is owned by iam_store_pod_identity.tf (dedicated role)

resource "aws_eks_pod_identity_association" "order_service" {
  cluster_name    = data.aws_ssm_parameter.eks_cluster_name.value
  namespace       = "order-service"
  service_account = "order-service-sa"
  role_arn        = data.aws_ssm_parameter.role_workload_pod_identity_arn.value
}
