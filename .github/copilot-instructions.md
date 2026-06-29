# Copilot instructions — devcon

JAWS-UG Iwata's web app + infrastructure monorepo (Dev Container based).
For details, see `docs/` and each `.github/instructions/*.instructions.md`.

## Architecture

- `services/api/` — backend REST API (Python / FastAPI / uvicorn)
- `services/web/` — frontend SPA (TypeScript / Vite + Vue 3)
- `infra/` — Terraform IaC (AWS, ap-northeast-1)
- `web` is a static SPA, `api` a stateless JSON API. The browser calls `api`
  only via `/api/*` and never touches AWS directly.
- The API contract is FastAPI's OpenAPI schema (`/openapi.json`) — the single
  source of truth. Generate frontend types with `make gen-types`; never
  hand-write them twice.

## Rules you must follow

- **Never merge directly to `main`.** Leave the PR open; merging is a human's
  call.
- **Never commit secrets.** `.env` / `*.tfvars` / keys are git-ignored. Commit
  `*.example` templates only.
- **No long-lived AWS keys.** Auth is GitHub OIDC → an IAM role per job. Don't
  add an `AWS_ACCESS_KEY_ID` secret. Deploys happen in CI, not locally.
- **Frontend env vars MUST be `VITE_`-prefixed and non-secret** (they ship to
  the browser). Backend secrets stay server-side (SSM / Secrets Manager).
- **Don't bypass pre-commit hooks with `--no-verify`.**
- "Green locally" must equal "green in CI." Lint with the exact CI command
  (e.g. `tflint --recursive`).

## Commands

Prefer the root `Makefile` (`make help`):
`make dev` / `make fmt` / `make lint` / `make test` / `make security` / `make gen-types`.
