# infra/bootstrap

One-time bootstrap for the remote-state backend and CI authentication.

This layer is **applied once, by a human, with local state**, _before_ any
pipeline runs. It is **NOT** managed by `cd-infra.yml` — that workflow manages
the app-infra layer, which depends on the resources created here.

## What it creates

- S3 bucket for Terraform **remote state** (versioned, SSE, public access blocked,
  TLS-only bucket policy that denies non-HTTPS access).
  State **locking** uses S3-native locking (`use_lockfile`) — no DynamoDB table.
- GitHub Actions **OIDC provider** (`token.actions.githubusercontent.com`).
- Two CI **IAM roles** assumed via OIDC:
  - `*-ci-plan` — read-only, assumed by PR pipelines to run `terraform plan`.
  - `*-ci-deploy` — assumed on push to `main` / the `production` environment
    to `terraform apply` and deploy the app.

## Apply once (local state)

```bash
cd infra/bootstrap

terraform init            # local backend — no -backend-config needed
terraform apply \
  -var 'github_org=YOUR_ORG' \
  -var 'github_repo=YOUR_REPO' \
  -var 'state_bucket_name=YOUR_GLOBALLY_UNIQUE_BUCKET'
```

Then wire the outputs into the app-infra layer:

- `state_bucket_name` → `infra/env/<env>.backend.hcl` (with `use_lockfile = true`)
- `ci_plan_role_arn` / `ci_deploy_role_arn` → GitHub repo variables used by
  `cd-infra.yml` and `cd-app.yml` (e.g. `AWS_PLAN_ROLE_ARN`,
  `AWS_DEPLOY_ROLE_ARN`).

## Notes

- Keep the local `terraform.tfstate` produced here safe (it is git-ignored).
  Optionally migrate it into the state bucket afterwards, but it must bootstrap
  itself with local state first.
- The state bucket has `prevent_destroy = true`. Removing it requires editing
  the lifecycle block deliberately.
- Until this layer is applied **and** `ci_plan_role_arn` / `ci_deploy_role_arn`
  are registered as the `AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` repo
  variables, `cd-infra.yml`'s plan/apply jobs fail at the AWS-credentials step
  — that is expected, not a regression. `ci.yml`'s `infra` job needs no AWS auth
  and stays green regardless.
