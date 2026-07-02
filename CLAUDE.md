# CLAUDE.md

Guidance for Claude Code in this repo. Area-specific rules live in nested `CLAUDE.md` files
(loaded on demand) and `docs/` — see **Map** and **More detail** below.

## Critical rules

- **Never merge to `main` without explicit confirmation.** Leave the PR open and say it's
  ready; merging is the user's call (`.claude/settings.json` has no allow entry for
  `gh pr merge` / `merge_pull_request`, so it defaults to asking).
- **"Green locally" must equal "green in CI."** CI mirrors the Makefile / pre-commit gates —
  e.g. `make tf-lint` runs the same `tflint --recursive --config` as CI (scanning
  `infra/bootstrap/` too), and `make ci-frontend` reproduces the CI frontend job. When
  changing any gate, keep all three layers in sync. An issue isn't done until the CI jobs
  actually go _green_.
- **No long-lived AWS keys; deploys happen in CI, not locally.** Auth is GitHub OIDC → an IAM
  role per job (read-only _plan_ for PRs, _deploy_ for main). Never add an `AWS_ACCESS_KEY_ID`
  secret; don't run `terraform apply`/`destroy` or push images by hand.
- **Never commit secrets.** `.env`, `*.tfvars`, credentials, keys are git-ignored — commit
  `.env.example` / `*.example` templates instead. Frontend env vars are `VITE_`-prefixed and
  non-secret (they ship to the browser); backend secrets stay server-side (SSM / Secrets Mgr).
- **Don't bypass hooks** with `--no-verify`. `pre-commit` runs fmt/lint/security (enable once
  with `make hooks`).

## Map

A monorepo in a Dev Container: a web app plus its infrastructure.

- `services/backend/python/` — backend REST API (Python, FastAPI, uvicorn). See
  `services/backend/python/CLAUDE.md`. Nested by language so future non-Python backend services
  can sit alongside it (e.g. `services/backend/go/`).
- `services/frontend/` — frontend SPA (TypeScript, Vite + Vue 3). See `services/frontend/CLAUDE.md`.
- `infra/` — Terraform IaC (AWS, `ap-northeast-1`). See `infra/CLAUDE.md`.

`frontend` is a static SPA, `backend` a stateless JSON API — separate processes. The browser
calls `/api/*` (Vite proxies to uvicorn in dev; CloudFront routes to the api origin in prod)
and never touches AWS directly. `backend` persists to PostgreSQL (RDS in prod, docker-compose
locally) via SQLAlchemy async. The API contract is FastAPI's OpenAPI schema (`/openapi.json`);
the frontend's types are generated from it (`make gen-types`) — never hand-written twice.

## Run locally

- `make dev` — Postgres container, then backend (:8000) and frontend (:5173) at once.
- App: http://localhost:5173 · API docs: http://localhost:8000/docs
- DB only: `make db-up` · apply migrations: `make migrate`.

## Commands (prefer the Makefile — `make help`)

- `make fmt` · `make lint` · `make test` · `make security` · `make gen-types`
- Per-area commands and conventions: see the nested `CLAUDE.md` in each subtree.

## More detail (plain references — read on demand, not auto-loaded)

- `docs/app-development.md` — backend / frontend structure, conventions, type generation.
- `docs/infrastructure.md` — Terraform 2-layer setup, CI/CD (`ci.yml` / `cd-infra.yml` /
  `cd-app.yml`), and the fresh-clone bootstrap order.
- `docs/issues.md` — working from a GitHub issue (branch, record findings, one focused PR).
- `docs/development-environment.md` — Dev Container usage.
- `docs/ai-instructions.md` — keeping these rules in sync with the Copilot
  `.github/instructions/*` mirror (change `docs/` + `CLAUDE.md` + Copilot files together).
- `docs/adr/` — Architecture Decision Records: record the "why" behind infra/architecture
  decisions; add an ADR when changing infra/CI-CD/service boundaries (see `adr/0001`).
- `docs/sdd.md` — upstream Spec-Driven Development workflow (cc-sdd `/kiro-*` skills, `.kiro/`
  layout, spec→`docs/` promotion). Don't let cc-sdd overwrite this `CLAUDE.md`: reinstall with
  `--overwrite skip --backup` and keep our curated version.
