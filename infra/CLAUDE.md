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

## Conventions

- 2-space indent; run `terraform fmt` (`make tf-fmt`).
- Tag resources via the provider's `default_tags` — don't hand-tag individual resources.
- State is remote (S3 + native locking). Never commit `*.tfstate`.
- Config lives in `env/*.tfvars` / `*.backend.hcl` (git-ignored); commit `*.example`
  templates only. Never commit secrets.

## Deploys happen in CI, not locally

Don't run `terraform apply`/`destroy` or push images by hand — `cd-infra.yml` (`apply` gated
behind manual `workflow_dispatch`, not automatic on merge to main — see `docs/infrastructure.md`
for why) owns app-infra changes. Auth is GitHub OIDC → an IAM role per job; never add an
`AWS_ACCESS_KEY_ID` secret.

See `docs/infrastructure.md` for `cd-infra.yml` / `cd-app.yml` detail.
See `docs/sandbox.md` for `sandbox/*` real-AWS verification.
