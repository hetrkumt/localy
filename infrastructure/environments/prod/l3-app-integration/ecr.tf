resource "aws_ecr_repository" "services" {
  for_each = toset([
    "edge-service",
    "store-service",
    "cart-service",
    "order-service",
    "payment-service",
    "user-service"
  ])

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
