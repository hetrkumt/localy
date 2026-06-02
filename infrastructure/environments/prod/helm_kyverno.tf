resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.3.4"
  namespace        = "kyverno"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "admissionController.failurePolicy"
    value = "Ignore"
  }

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller
  ]
}
