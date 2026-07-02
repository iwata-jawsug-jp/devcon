---
applyTo: 'infra/**'
---

# Infra (Terraform / AWS)

Details: `docs/infrastructure.md`, `infra/CLAUDE.md`.

- Tag resources via the provider's `default_tags`. Don't hand-tag individual
  resources.
- Lint with `make tf-lint` — it runs the same `tflint --recursive --config` as
  CI (scanning `bootstrap/` too).
- State is remote (S3 + native locking). Never commit `*.tfstate`.
- Config lives in `env/*.tfvars` / `*.backend.hcl` (git-ignored). Commit
  `*.example` templates only. Never commit secrets.
- Don't run `terraform apply` / `destroy` or push images locally. App-infra
  changes are owned by `cd-infra.yml` (`apply` is gated behind manual
  `workflow_dispatch`, not automatic on merge to main).
- Auth is GitHub OIDC → an IAM role per job. Don't add an `AWS_ACCESS_KEY_ID`
  secret.
- `bootstrap/` is the layer applied once with local state, not managed by
  `cd-infra.yml`.
