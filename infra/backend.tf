# Remote state backend (S3 with native locking).
#
# This uses a PARTIAL backend config: the block below is intentionally empty.
# Backend settings cannot reference variables, so concrete per-environment values
# (bucket / key / region / use_lockfile) live in `env/<env>.backend.hcl` and are
# supplied at init time:
#
#   terraform init -backend-config=env/dev.backend.hcl
#
# State locking uses S3-native locking (`use_lockfile = true`) — no DynamoDB
# table. The S3 state bucket itself is created by `infra/bootstrap/`.
terraform {
  backend "s3" {}
}
