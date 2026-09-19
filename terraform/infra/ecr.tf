locals {
  images = toset(["telemetry-processor", "realtime-router", "dashboard-api", "rbac-authz", "vehicle-simulator", "web"])
}

resource "aws_ecr_repository" "this" {
  for_each             = local.images
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # destroy.sh removes repositories even when they contain images

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}
