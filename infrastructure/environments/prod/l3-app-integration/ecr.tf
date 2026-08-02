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
  # Wave 1: immutable tags — CI must push unique sha-* (never overwrite latest/e2e*).
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# FinOps retention (Wave 1):
# 1) untagged → 7d
# 2) sha-* keep last 50 (prod rollback window; safer than blind 30d expiry)
# 3) pr-* → 14d
# Legacy e2e* pins are left untouched until promotion fully migrates to sha-*.
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 50 sha-* tags for deterministic rollback"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 50
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 3
        description  = "Expire pr-* tags after 14 days"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["pr-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
