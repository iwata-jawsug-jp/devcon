---
applyTo: 'infra/**'
---

# Infra (Terraform / AWS)

Details: `docs/infrastructure.md`, `infra/CLAUDE.md`.

- Tag resources via the provider's `default_tags`. Don't hand-tag individual
  resources.
- Lint with the exact CI command `tflint --recursive` (it scans `bootstrap/`
  too). A green `make tf-lint` alone is not proof CI is green.
- State is remote (S3 + native locking). Never commit `*.tfstate`.
- Config lives in `env/*.tfvars` / `*.backend.hcl` (git-ignored). Commit
  `*.example` templates only. Never commit secrets.
- Don't run `terraform apply` / `destroy` or push images locally. App-infra
  changes are owned by `cd-infra.yml` (gated by the `production` Environment on
  merge to main).
- Auth is GitHub OIDC → an IAM role per job. Don't add an `AWS_ACCESS_KEY_ID`
  secret.
- `bootstrap/` is the layer applied once with local state, not managed by
  `cd-infra.yml`.
