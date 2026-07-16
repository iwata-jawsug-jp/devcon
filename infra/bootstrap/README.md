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

**Recommended: use `tools/script/bootstrap.sh`** (#491) instead of the manual steps below —
it auto-detects the GitHub org/repo (`gh repo view` / `git remote get-url origin`) and the AWS
account ID (`aws sts get-caller-identity`), generates a globally-unique state bucket name
(`terraform-<project>-<account_id>-<random6>`), and detects whether a GitHub Actions OIDC
provider already exists in this AWS account (IAM allows only one per URL per account — e.g. a
sibling repo's bootstrap in a shared account may have already created it) so it isn't
recreated:

```bash
tools/script/bootstrap.sh init -p <project>   # first time (org/repo/bucket/region auto-detected or overridable)
tools/script/bootstrap.sh update              # re-apply after changing main.tf (no parameters needed)
tools/script/bootstrap.sh write                # push outputs to repo variables + generate infra/env/*.backend.hcl / *.tfvars
tools/script/bootstrap.sh destroy              # tear down (state bucket kept unless --include-state-bucket)
```

See `./tools/script/bootstrap.sh --help` for all options (`-o/-r/-b/-R` overrides, `--force` on
`write`, `--include-state-bucket` on `destroy`). The manual steps below remain as a reference /
fallback.

> **Brand-new AWS account/region prerequisite**: `main.tf` reads the account's
> default AWS-managed KMS keys via `data "aws_kms_alias"` (`alias/aws/rds`,
> `alias/aws/secretsmanager`) to scope the `ci_deploy` IAM policy. Those aliases
> are created lazily by AWS the first time each service is actually used with
> its default key — in an account/region that has never created an RDS
> instance or a Secrets Manager secret, the alias doesn't exist yet and
> `terraform apply` fails with `Error: reading KMS Alias ...: empty result`.
> If you hit that, warm up the missing key once before re-running `apply`:
>
> ```bash
> aws secretsmanager create-secret --name kms-bootstrap-warmup --secret-string x
> aws secretsmanager delete-secret --secret-id kms-bootstrap-warmup --force-delete-without-recovery
> ```

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
- `project` → GitHub repo variable `PROJECT_NAME`. `cd-infra.yml` (and the
  sandbox/verify variants) substitute this into `infra/env/*.example`'s
  `devcon` placeholder at materialize time -- it must match the
  `project` this bootstrap was applied with, since `ci_plan`'s state-lock IAM
  policy is scoped to `${var.project}/dev/terraform.tfstate.tflock`. A
  mismatch here surfaces as an `AccessDenied` on the state lock object during
  `terraform plan`, not as an auth failure.

## Notes

- Keep the local `terraform.tfstate` produced here safe (it is git-ignored).
  Optionally migrate it into the state bucket afterwards, but it must bootstrap
  itself with local state first.
- The state bucket has `prevent_destroy = true`. Removing it requires editing
  the lifecycle block deliberately (`tools/script/bootstrap.sh destroy --include-state-bucket`
  automates this: it flips the flag, destroys the bucket, then always restores the file).
- `create_oidc_provider` (default `true`) controls whether this bootstrap creates the
  GitHub Actions OIDC provider or reuses one that already exists in the AWS account
  (`bootstrap.sh init` detects this automatically via `aws iam list-open-id-connect-providers`).
- `bootstrap.sh destroy` never removes the OIDC provider by default, even if this bootstrap
  created it -- other repos sharing the same AWS account may have reused it via
  `create_oidc_provider = false`. Pass `--include-oidc-provider` to opt in; it still asks a
  separate y/N question (not skipped by `-y`/`--yes`) and is a no-op if this bootstrap doesn't
  own the resource in the first place.
- Until this layer is applied **and** `ci_plan_role_arn` / `ci_deploy_role_arn` /
  `project` are registered as the `AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` /
  `PROJECT_NAME` repo variables, `cd-infra.yml`'s plan/apply jobs fail at the
  AWS-credentials step (or, if `PROJECT_NAME` is missing/wrong, at the state-lock
  `AccessDenied` a few steps later) — that is expected, not a regression.
  `ci.yml`'s `infra` job needs no AWS auth and stays green regardless.
