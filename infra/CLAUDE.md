# infra — Terraform IaC (AWS)

Loaded on demand when working in `infra/`. Root rules still apply; see `../CLAUDE.md`.
Full guide: `docs/infrastructure.md`.

## Two layers

- **`bootstrap/`** — applied once, with local state, _before_ any pipeline runs. Creates the
  S3 state bucket (native locking via `use_lockfile`, referenced by `backend.tf`), the GitHub
  OIDC provider, and the CI IAM roles (read-only _plan_ for PRs, _deploy_ for main). Not
  managed by `cd-infra.yml`. Setup steps and the fresh-clone bootstrap order are in
  `docs/infrastructure.md`.
- **app infra** (`*.tf`) — managed by `cd-infra.yml` using remote state. web → private S3
  with CloudFront (OAC); api → ECR + ECS Fargate behind an ALB; db → RDS for PostgreSQL in
  private subnets (RDS-managed credentials in Secrets Manager, reachable only from the app
  SG); shared → VPC, CloudWatch logs, task/exec IAM roles.

Remote state per env: `terraform init -backend-config=env/<env>.backend.hcl`; values in
`env/<env>.tfvars`. Region defaults to `ap-northeast-1`.

## Commands

- `make tf-init` · `make tf-plan` · `make tf-validate` · `make security` (Trivy + Checkov)
- **Lint:** `make tf-lint` runs the same `tflint --recursive --config=.tflint.hcl` as CI
  (it scans `bootstrap/` too).
- **Policy as Code:** `make policy-test` runs `conftest verify` (Rego unit tests) over
  `infra/policy/*.rego` — org-specific conventions generic scanners can't express (required
  tags, IAM wildcard-action ban; see #296, [ADR-0017](../docs/adr/0017-policy-as-code-conftest.md)).
  Add a policy by dropping a `.rego` + `_test.rego` pair in `infra/policy/` — no workflow
  changes needed. `conftest test` against a real plan only runs in `cd-infra.yml`'s `plan`
  job (needs the AWS plan role); locally/pre-commit/`ci.yml` only run the AWS-credential-free
  unit tests.

## Conventions

- 2-space indent; run `terraform fmt` (`make tf-fmt`).
- Tag resources via the provider's `default_tags` — don't hand-tag individual resources.
- **Naming: `local.name_prefix` vs. `local.global_name_prefix` (main.tf).** Most resource names
  only need to be unique within this AWS account/region, so use `local.name_prefix`
  (`"${var.project}-${var.environment}"`). A few resource types (S3 bucket names, Cognito Hosted
  UI domain prefixes) are namespaced **globally across all AWS accounts** — using `name_prefix`
  alone collides across different forks/clones of this template that keep the default `project`
  value (#436). Use `local.global_name_prefix` (`name_prefix` + the account id) for those.
- State is remote (S3 + native locking). Never commit `*.tfstate`.
- Config lives in `env/*.tfvars` / `*.backend.hcl` (git-ignored); commit `*.example`
  templates only. Never commit secrets.

## Deploys happen in CI, not locally

Don't run `terraform apply`/`destroy` or push images by hand — `cd-infra.yml` (`apply` gated
behind manual `workflow_dispatch`, not automatic on merge to main — see `docs/infrastructure.md`
for why) owns app-infra changes. `apply` also requires the `INFRA_APPLY_ENABLED` repo variable
set to `true` (defaults to disabled — see `docs/ci-cd-area-switches.md`), a second key on top of
`workflow_dispatch` itself. Auth is GitHub OIDC → an IAM role per job; never add an
`AWS_ACCESS_KEY_ID` secret.

See `docs/infrastructure.md` for `cd-infra.yml` / `cd-app.yml` detail.
See `docs/sandbox.md` for `sandbox/*` real-AWS verification.
