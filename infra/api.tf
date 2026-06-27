# Api service hosting: container registry + (TODO) ECS Fargate behind an ALB.

# ECR repository for the api image built/pushed by cd-app.yml.
resource "aws_ecr_repository" "api" {
  name                 = "${local.name_prefix}-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Keep only a bounded number of images to control storage cost.
resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      }
    ]
  })
}

# TODO: ECS Fargate service for the api.
#   - aws_ecs_cluster
#   - aws_ecs_task_definition (uses var.container_image, log group from shared.tf)
#   - aws_ecs_service wired to a private subnet + the ALB target group
#   - aws_lb (ALB) + listener + target group; `/api/*` reached via CloudFront
#   - security groups: ALB (ingress 443) -> service (ingress from ALB only)
#
# Alt deployment shape (cheaper for low traffic): Lambda (container image from
# the same ECR repo) + API Gateway / Function URL instead of ECS + ALB.
