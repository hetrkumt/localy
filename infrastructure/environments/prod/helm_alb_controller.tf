# ========================================================================
# ALB Controller Helm Release
# ========================================================================
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  depends_on = [
    kubernetes_service_account_v1.aws_lbc_sa,
    aws_eks_addon.ebs_csi,
  ]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = "ap-northeast-2"
  }

  set {
    name  = "vpcId"
    value = module.network.vpc_id
  }

  # ServiceMonitor CRD는 kube-prometheus-stack이 ALB 이후에 배포되므로 비활성화합니다.
  set {
    name  = "serviceMonitor.enabled"
    value = "false"
  }
}
