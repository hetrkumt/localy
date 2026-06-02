resource "kubectl_manifest" "kyverno_fluentbit_exclude_policy" {
  yaml_body = file("${path.module}/kyverno-policy.yaml")

  depends_on = [
    helm_release.kyverno
  ]
}
