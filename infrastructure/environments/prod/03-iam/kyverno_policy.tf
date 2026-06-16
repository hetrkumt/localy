resource "kubectl_manifest" "kyverno_cluster_policies" {
  yaml_body = file("${path.module}/kyverno-policy.yaml")
}

resource "kubectl_manifest" "kyverno_protect_alertmanager" {
  yaml_body = file("${path.module}/protect-alertmanager.yaml")
}
