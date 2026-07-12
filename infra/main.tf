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

  # S3 bucket names and Cognito Hosted UI domain prefixes are unique
  # *globally* (across all AWS accounts), not just within this account/region
  # -- unlike most other resource names in this layer. `name_prefix` alone
  # (e.g. "devcon-sandbox") collides across different forks/clones of this
  # template using the default `project` value (#436). Suffixing with the
  # account id keeps those two resource types unique without requiring every
  # user to pick a bespoke `project` name.
  global_name_prefix = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
}

# Handy lookups available to resources across the layer.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
