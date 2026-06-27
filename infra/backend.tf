# Remote state backend (S3 + DynamoDB lock).
#
# This uses a PARTIAL backend config: the block below is intentionally empty.
# Backend settings cannot reference variables, so concrete per-environment values
# (bucket / key / region / lock table) live in `env/<env>.backend.hcl` and are
# supplied at init time:
#
#   terraform init -backend-config=env/dev.backend.hcl
#
# The S3 bucket + DynamoDB table themselves are created by `infra/bootstrap/`.
terraform {
  backend "s3" {}
}
