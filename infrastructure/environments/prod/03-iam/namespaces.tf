resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "managed-by" = "terraform"
    }
  }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = "observability"
    labels = {
      "managed-by" = "terraform"
    }
  }
}
