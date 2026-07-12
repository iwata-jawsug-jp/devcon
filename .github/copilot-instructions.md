# Copilot instructions — devcon

JAWS-UG Iwata's web app + infrastructure monorepo (Dev Container based).
For details, see `docs/` and each `.github/instructions/*.instructions.md`.

## Architecture

- `services/backend/python/` — backend REST API (Python / FastAPI / uvicorn), nested by
  language so future non-Python backend services can sit alongside it
- `services/frontend/` — frontend SPA (TypeScript / Vite + Vue 3)
- `infra/` — Terraform IaC (AWS, ap-northeast-1)
- `frontend` is a static SPA, `backend` a stateless JSON API. The browser calls the backend
  only via `/api/*` and never touches AWS directly.
- The API contract is FastAPI's OpenAPI schema (`/openapi.json`) — the single
  source of truth. Generate frontend types with `make gen-types`; never
  hand-write them twice.

## Rules you must follow

- **Respond in Japanese in chat by default.** Code, commit messages, PR/issue bodies, and
  other artifacts still follow existing conventions (English/Japanese mixed); this only
  governs the conversational reply language.
- **Never merge directly to `main`.** Leave the PR open; merging is a human's
  call.
- **Never commit secrets.** `.env` / `*.tfvars` / keys are git-ignored. Commit
  `*.example` templates only.
- **No long-lived AWS keys.** Auth is GitHub OIDC → an IAM role per job. Don't
  add an `AWS_ACCESS_KEY_ID` secret. Deploys happen in CI, not locally.
- **Frontend env vars MUST be `VITE_`-prefixed and non-secret** (they ship to
  the browser). Backend secrets stay server-side (SSM / Secrets Manager).
- **Don't bypass pre-commit hooks with `--no-verify`.**
- "Green locally" must equal "green in CI." The Makefile targets mirror the CI
  commands (e.g. `make tf-lint` == CI's `tflint --recursive --config`, and
  `make ci-frontend` reproduces the CI frontend job).
- **CI green proves the code is correct, not that a deploy actually works.** Config injection,
  CSP, and VPC routing don't exist in local dev or CI. The 4th gate is a live-browser E2E smoke
  test (`services/frontend/e2e/live-smoke/`) that drives a real Cognito Hosted UI login plus an
  authenticated write against the just-deployed environment (`cd-app-sandbox.yml`/`cd-app.yml`'s
  `smoke-test` job) — blocking, not advisory. On `main` it only runs once the
  `LIVE_SMOKE_ENABLED` repo variable is set to `true` (defaults to disabled).

## Commands

Prefer the root `Makefile` (`make help`):
`make dev` / `make fmt` / `make lint` / `make test` / `make security` / `make gen-types`.

## Spec-driven workflow

`/kiro-*` skills under `.claude/skills/` (steering, requirements, design, tasks) are usable
as-is from Copilot CLI — see `docs/sdd.md` for the workflow and known Copilot caveats.
