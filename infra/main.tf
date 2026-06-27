# Entry point for infrastructure resources.
#
# Add resources / module calls here. Example layout for growth:
#   modules/        -> reusable building blocks
#   env/dev.tfvars  -> per-environment values
#
# `locals` for naming convention shared across resources.
locals {
  name_prefix = "${var.project}-${var.environment}"
}

# Handy lookups available to resources below.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
