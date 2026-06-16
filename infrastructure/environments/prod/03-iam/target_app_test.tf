# Target application for WAF/ALB validation
# Deploys a simple nginx service and ClusterIP service in the default namespace.

resource "kubernetes_deployment_v1" "target_app" {
  metadata {
    name      = "nginx-target-app"
    namespace = "default"
    labels = {
      app = "nginx-target"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "nginx-target"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx-target"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "target_svc" {
  metadata {
    name      = "nginx-target-svc"
    namespace = "default"
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "nginx-target"
    }

    port {
      port        = 80
      target_port = 80
    }
  }
}
