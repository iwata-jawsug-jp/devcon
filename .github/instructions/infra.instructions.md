---
applyTo: 'infra/**'
---

# Infra (Terraform / AWS)

Details: `docs/infrastructure.md`, `infra/CLAUDE.md`.

- Tag resources via the provider's `default_tags`. Don't hand-tag individual
  resources.
- Naming: use `local.name_prefix` for most resources (unique within this AWS
  account/region). Use `local.global_name_prefix` (`name_prefix` + account id,
  `main.tf`) for resource types namespaced globally across all AWS accounts
  (S3 bucket names, Cognito Hosted UI domain prefixes) — `name_prefix` alone
  collides across forks of this template.
- Lint with `make tf-lint` — it runs the same `tflint --recursive --config` as
  CI (scanning `bootstrap/` too).
- State is remote (S3 + native locking). Never commit `*.tfstate`.
- Config lives in `env/*.tfvars` / `*.backend.hcl` (git-ignored). Commit
  `*.example` templates only. Never commit secrets.
- Don't run `terraform apply` / `destroy` or push images locally. App-infra
  changes are owned by `cd-infra.yml` (`apply` is gated behind manual
  `workflow_dispatch`, not automatic on merge to main). `apply` also requires the
  `INFRA_APPLY_ENABLED` repo variable set to `true` (defaults to disabled), a second key on
  top of `workflow_dispatch` itself.
- Auth is GitHub OIDC → an IAM role per job. Don't add an `AWS_ACCESS_KEY_ID`
  secret.
- `bootstrap/` is the layer applied once with local state, not managed by
  `cd-infra.yml`.
