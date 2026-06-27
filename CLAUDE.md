# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A monorepo developed inside a Dev Container. It hosts a **web application** plus its
**infrastructure (Terraform/AWS)**:

- `services/api/` — backend **REST API** (Python, **FastAPI**, served by uvicorn).
- `services/web/` — frontend **SPA** (TypeScript, **Vite + Vue 3**).
- `infra/` — Terraform IaC that provisions where the app runs.

## Architecture

- `web` is a static SPA; `api` is a stateless JSON API. Separate processes.
- The browser calls the API at a relative `/api/*` path. In dev, Vite (:5173) proxies
  `/api/*` to uvicorn (:8000) — no CORS needed locally. In prod, CloudFront routes
  `/api/*` to the api origin.
- The browser never calls AWS directly; all data goes through `api`.
- `api` persists to **PostgreSQL** — RDS in AWS, docker-compose locally — via **SQLAlchemy
  async (asyncpg)**. Schema changes go through **Alembic** migrations; DB credentials come
  from Secrets Manager in prod (never from the browser).
- API contract = FastAPI's OpenAPI schema (`/openapi.json`). Generate the TS client/types
  from it (`openapi-typescript`, `make gen-types`); never hand-write request/response
  types in two places.

## Layout

- `infra/` — Terraform IaC. Region defaults to `ap-northeast-1`. State config in
  `infra/backend.tf`.
- `services/api/` — uv-managed (`pyproject.toml`, `src/api`, `tests/`).
  - `src/api/main.py` exposes the FastAPI `app`. Routers in `src/api/routers/`,
    Pydantic models in `src/api/schemas/`, settings in `src/api/config.py`
    (`pydantic-settings`). Inject dependencies with `Depends`.
  - DB layer in `src/api/db/` (SQLAlchemy `Base`, async engine/session, ORM models),
    data access in `src/api/repositories/`, migrations in `alembic/`. Routers get an
    `AsyncSession` via `Depends(get_session)` and go through a repository — no raw SQL
    in handlers.
- `services/web/` — Vite app (`package.json`, `vite.config.ts`, `tsconfig.json`, `src/`).
  - SFCs use `<script setup lang="ts">`. Components in `src/components/`, route views in
    `src/views/`, router in `src/router/`, generated API client in `src/api/`,
    shared state (if any) via Pinia in `src/stores/`.

## Run locally

- Both at once: `make dev` (starts the Postgres container, then api on :8000, web on :5173).
- DB only: `make db-up` (Postgres via docker-compose) · apply migrations: `make migrate`.
- api only: `cd services/api && uv run uvicorn api.main:app --reload`
- web only: `cd services/web && npm run dev`
- App: http://localhost:5173 · API docs: http://localhost:8000/docs

## Commands (prefer the Makefile — `make help`)

- Format: `make fmt` · Lint: `make lint` · Test: `make test` · Security scan: `make security`
- Generate TS types from the API: `make gen-types`
- Terraform: `make tf-init`, `make tf-plan`, `make tf-lint`
- Python: `cd services/api && uv run pytest` (use `uv run`, never bare `python`/`pip`)
- Web: `cd services/web && npm test` (Vitest unit) · `npm run test:e2e` (Playwright)
- DB: `make db-up` / `make migrate` (alembic upgrade) / `make makemigration m="..."` (autogenerate)

## Conventions

- Python: ruff (line length 100, `py312`), mypy strict — keep type hints. Validate request
  and response bodies with Pydantic models, not raw dicts. Async route handlers.
- Database: SQLAlchemy 2.0 async (`Mapped[...]` typed models), access via repositories, not
  raw SQL in routers. Every schema change is an Alembic migration (`make makemigration`);
  never edit the DB by hand. Tests default to in-memory SQLite (aiosqlite) and run against
  Postgres in CI.
- Vue/TypeScript: strict mode, ESM, Composition API with `<script setup>`. Type-check with
  **`vue-tsc`** (not `tsc`). Call the API only through the generated client in `src/api/`,
  not ad-hoc `fetch`.
- Terraform: 2-space indent, run `terraform fmt`; tag resources via provider `default_tags`.
- Config from env vars only. Frontend vars MUST be `VITE_`-prefixed and non-secret — they
  ship to the browser. Backend secrets stay server-side (SSM / Secrets Manager).
- Never commit secrets. `.env`, `*.tfvars`, credentials, keys are git-ignored; commit
  `.env.example` / `*.example` templates instead.

## Before committing

`pre-commit` runs fmt/lint/security automatically. Run `make hooks` once to enable.
Don't bypass hooks with `--no-verify`.

## CI/CD (GitHub Actions)

Workflows live in `.github/workflows/`. CI mirrors the Makefile / pre-commit gates, so
"green locally" == "green in CI".

- `ci.yml` (PR + push to main): per-service jobs, run only for changed paths.
  - api: `uv sync` → ruff → mypy → pytest
  - web: `npm ci` → eslint → `vue-tsc --noEmit` → vitest → build (→ Playwright e2e)
  - infra: `terraform fmt -check` → `init -backend=false` → validate → tflint → checkov + trivy
- `cd-infra.yml`: `terraform plan` on PR (posted as a comment); `apply` only on merge to
  main, gated by a protected GitHub Environment (`production`).
- `cd-app.yml` (runs after infra exists): `build` (push api image to ECR, tag=SHA) →
  `migrate` (dedicated job: register a new task-def revision with that image, then run
  `alembic upgrade head` as a one-off Fargate task on it, gated before the roll) →
  `deploy-api` (roll the ECS service to the new revision — ECR tags are IMMUTABLE, so a
  new revision per build is required); web builds, syncs `dist/` to S3, invalidates CloudFront.

### CI/CD rules

- **No long-lived AWS keys.** Auth is GitHub OIDC → an IAM role assumed per job: a
  read-only *plan* role for PRs, a *deploy* role for main. Never add an
  `AWS_ACCESS_KEY_ID` secret.
- Deploys happen in CI, **not locally** — don't run `terraform apply` or push images by
  hand. (`.claude/settings.json` already gates `terraform apply`/`destroy`/`aws`/`git push`
  for confirmation.)
- Secrets come from GitHub Environments / SSM / Secrets Manager, never committed.

## Working from issues

When implementing a GitHub issue, follow this loop:

- **Branch from up-to-date `main`**, one branch per issue. Name it `fix/<slug>` for bugs,
  `feat/<slug>` for features. Don't reuse an unrelated branch (e.g. a sandbox branch).
- **Record findings as you discover them, in the issue, before fixing them.** Debugging is a
  loop, not a fixed 3-step flow: comment on (1) start — branch + plan; then for *each* cause
  you find — especially new root causes CI surfaces mid-fix — post the finding *before*
  applying its fix, followed by the change + commit SHA; and (3) the verified result at the
  end. Never batch findings up to record them later. Keep comments short and factual
  (diffs, run URLs).
- **One issue → one focused PR.** Link it with `Closes #N` in the PR body (and the commit
  message). Keep the diff scoped to that issue; spin off unrelated findings into new issues.
- **An issue isn't done until CI actually passes.** Watch `gh pr checks <pr> --watch` and
  confirm the relevant jobs go *green* — "the job was triggered" or "it ran" is not success.
  Read failing logs (`gh run view --job <id> --log-failed`) before claiming a fix works.
- **Verify locally with the same command CI runs**, not a looser local variant. CI runs
  `tflint --recursive` (it scans `infra/bootstrap/` too) while `make tf-lint` does not — a
  green Makefile target is not proof CI is green. When in doubt, mirror the workflow step.
- **Correct the record when a finding turns out wrong.** If investigation shows an issue's
  stated root cause is inaccurate, comment the accurate cause rather than leaving it stale.
- **Never merge to `main` without explicit confirmation.** Leave the PR open and say it's
  ready; merging is the user's call (see also the gates in `.claude/settings.json`).

## Infrastructure (infra/)

Two layers:

- **bootstrap/** — applied once, with local state, *before* any pipeline runs. Creates the
  S3 state bucket with native locking (`use_lockfile`, referenced by `infra/backend.tf`),
  the GitHub OIDC provider, and the CI IAM roles (plan + deploy). Not managed by `cd-infra.yml`.
- **app infra** — managed by `cd-infra.yml`, using remote state:
  - web → S3 (private) + CloudFront (OAC) [+ ACM / Route53 for a custom domain]
  - api → ECR + ECS Fargate behind an ALB  (**alt:** Lambda + API Gateway / Function URL)
  - db → RDS for PostgreSQL in private subnets; credentials are RDS-managed in Secrets
    Manager (`manage_master_user_password`). Reachable only from the app security group.
  - shared → VPC (public/private subnets), CloudWatch logs, task/exec IAM roles

Remote state per env: `terraform init -backend-config=env/<env>.backend.hcl`; values in
`infra/env/<env>.tfvars`. Region `ap-northeast-1`. All resources tagged via `default_tags`.

## Bootstrap order (for a fresh clone)

1. `make setup` — toolchains + git hooks.
2. Apply `infra/bootstrap/` once (local state): state bucket (native locking), OIDC, IAM roles.
3. Migrate app infra to remote state: `terraform init -migrate-state`.
4. First `cd-infra.yml` run provisions app infra; then enable `cd-app.yml`.
