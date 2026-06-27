# Entry point / shared locals + data sources for the app-infra layer.
#
# Resources are split by purpose into:
#   shared.tf -> VPC, CloudWatch logs, shared IAM (foundational)
#   web.tf    -> SPA hosting (S3 + CloudFront)
#   api.tf    -> api service (ECR + ECS Fargate behind an ALB)
#
# Per-environment values live in `env/<env>.tfvars`; remote state is configured
# via `env/<env>.backend.hcl` (see backend.tf).

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Handy lookups available to resources across the layer.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
