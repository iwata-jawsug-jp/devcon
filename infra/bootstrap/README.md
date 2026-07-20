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
- One **agent-only IAM role** (`*-agent-mcp`, #571): read-only (`ReadOnlyAccess` + guardrail
  Denies), assumed locally by a human via the AWS MCP Server (Claude Code) — not OIDC, not
  used by CI, never registered as a GitHub repo variable. See
  `docs/aws-temporary-credentials.md` for how to assume it from the devcontainer.

Every IAM role/policy name above is actually `<project>-<suffix>-...` (`local.name_prefix`,
locals.tf, #571) — `<suffix>` is a random 6-char token (`var.resource_name_suffix`, the same
one `bootstrap.sh init` uses for the state bucket name). It exists so that re-running `init`
after the local state that tracked a prior apply was lost/discarded always gets a fresh,
unclaimed name instead of hitting `EntityAlreadyExists` against the still-existing AWS-side
resources from that prior attempt.

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
tools/script/bootstrap.sh update              # re-apply after changing infra/bootstrap/*.tf (no parameters needed)
tools/script/bootstrap.sh write                # push outputs to repo variables + generate infra/env/*.backend.hcl / *.tfvars
tools/script/bootstrap.sh destroy              # tear down (state bucket kept unless --include-state-bucket)
```

See `./tools/script/bootstrap.sh --help` for all options (`-o/-r/-b/-R` overrides, `--force` on
`write`, `--include-state-bucket` on `destroy`). The manual steps below remain as a reference /
fallback.

### Using this on a second dev machine

`init`/`update`/`destroy` need the local `terraform.tfstate` this layer produces (see "Notes"
below for why it can't have a remote backend), so they only work on the one machine that ran
`init`. A second dev machine doesn't need that state — it just needs the values `write` already
published as repo variables (`PROJECT_NAME` / `AWS_TF_STATE_BUCKET` / `AWS_PLAN_ROLE_ARN` /
`AWS_DEPLOY_ROLE_ARN`). Run:

```bash
tools/script/bootstrap.sh adopt
```

It reads those repo variables (override any of them with `-p`/`-b`/`--plan-role-arn`/
`--deploy-role-arn` if `gh` can't read them), verifies the state bucket and both IAM roles
actually exist under the AWS credentials active on this machine, then generates
`infra/env/*.backend.hcl` / `*.tfvars` locally — without creating any Terraform state here. If
the verification fails (e.g. this machine is authenticated against a different AWS account),
`adopt` stops with an error instead of writing files from unverified values. `update`/`destroy`
for `infra/bootstrap` itself still must run from the original `init` machine.

### Automatic state backup

Every successful `init`/`update` (and the import-based path of `recover`, below) uploads
`terraform.tfstate` and `terraform.auto.tfvars` to `s3://<state bucket>/_bootstrap-state-backup/`
— inside the very bucket this layer creates, under a key prefix that doesn't overlap with the
app layer's own remote-state keys or `ci_plan`'s read-only `dev`-key scoping. The bucket's
existing versioning means an accidental bad backup doesn't destroy the previous one. This isn't
a Terraform remote backend (bootstrap still can't depend on the bucket it itself creates — see
"Notes" below); it's a plain object copy that `recover` can pull down directly, without needing
to re-derive state from AWS one resource at a time.

### If the `init` machine itself is lost

If the one machine holding the local state is gone (disk failure, container rebuild, etc.):

```bash
tools/script/bootstrap.sh recover
```

It first tries restoring `terraform.tfstate`/`terraform.auto.tfvars` from the S3 backup above —
if one exists, this is all `recover` does (fast, and exact: no import-ID guessing). Only when no
backup is found (or `--no-restore` is passed) does it fall back to rebuilding state from AWS
directly: like `adopt`, it reads the repo variables `write` published (or explicit `-p`/`-b`/
`--plan-role-arn`/`--deploy-role-arn` overrides), verifies the referenced AWS resources exist,
then runs `terraform init` and `terraform import` for every resource this layer declares (the S3
state bucket and its sub-resources, all IAM roles, policies, and attachments) and writes
`terraform.auto.tfvars`, so `update`/`write`/`destroy` work again from this machine. It's safe to
re-run: already-imported resources are skipped, so a partial failure (e.g. one wrong assumption
about a resource name) can be fixed and retried without redoing the rest.

The GitHub Actions OIDC provider is the one exception: whether _this_ bootstrap created it or
merely reused one a sibling repo's bootstrap already created isn't something AWS records, so
`recover` never imports it unless you pass `--owns-oidc-provider` (only do this if you're sure
— importing it when you're not gives this state destroy authority over a resource another
repo's CI may depend on).

After it finishes, run `terraform -chdir=infra/bootstrap plan` and confirm it reports no
changes — that's the signal the reconstructed state actually matches the imported values (a
mismatched import ID would otherwise show up there as spurious diffs, not as an import error).
Verified end-to-end against a real applied environment: `terraform plan` reported no changes
after a full `recover` from a deleted `terraform.tfstate`.

> **Brand-new AWS account/region prerequisite**: `iam-ci-deploy-data.tf` reads the account's
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

## Consuming this from another project

This directory is self-contained (its own `providers.tf`/`versions.tf`, no `backend`
block) and can be pulled into another project two ways — no dedicated module
repository exists or is planned ([ADR-0016](../../docs/adr/0016-terraform-bootstrap-module-distributed-in-repo.md),
same "this repo is the distributable" reasoning as [ADR-0011](../../docs/adr/0011-scaffold-template-in-place.md)/
[ADR-0012](../../docs/adr/0012-reusable-workflow-in-repo-tag-versioned.md)):

- **Whole new project**: `copier copy gh:iwata-jawsug-jp/devcon <target>` (#294) — gets
  this directory (placeholders substituted) along with the rest of the template.
  Use this when starting a fresh project.
- **Bootstrap only, into an existing project**:
  ```bash
  terraform init -from-module="git::https://github.com/iwata-jawsug-jp/devcon.git//infra/bootstrap?ref=vX.Y.Z"
  ```
  Pin an actual release tag (see [Releases](https://github.com/iwata-jawsug-jp/devcon/releases)),
  not a branch — Git source references have no version-range resolution, so the
  consumer is responsible for tracking updates manually (#298).

`devcon` is a private repository, so the Git source path above only works for
consumers with read access to it (e.g. itouhi's own other repos, authenticated via the
same `gh`/git credential helper). A genuine third party (outside that access boundary)
should instead reference the public mirror, `iwata-jawsug-jp/devcon` — same reasoning
ADR-0012 applied to the reusable-workflow reference target.
