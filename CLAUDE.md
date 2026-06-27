# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A monorepo for **infrastructure (Terraform/AWS)** plus **application development**
(Python and Node/TypeScript), developed inside a Dev Container.

## Layout

- `infra/` — Terraform IaC. Region defaults to `ap-northeast-1`. Remote state config is
  commented in `infra/backend.tf`.
- `services/api/` — Python app, managed with **uv** (`pyproject.toml`, `src/api`, `tests/`).
- `services/web/` — Node/TypeScript app (`package.json`, `tsconfig.json`, `src/`).

## Commands (prefer the Makefile — `make help`)

- Format: `make fmt` · Lint: `make lint` · Test: `make test` · Security scan: `make security`
- Terraform: `make tf-init`, `make tf-plan`, `make tf-lint`
- Python: `cd services/api && uv run pytest` (use `uv run`, not bare `python`/`pip`)
- Node: `cd services/web && npm test` / `npm run dev`

## Conventions

- Python: ruff (line length 100, `py312` target), mypy strict. Keep type hints.
- TypeScript: strict mode, ESM (`type: module`), eslint + prettier.
- Terraform: 2-space indent, run `terraform fmt`; tag resources via provider `default_tags`.
- Never commit secrets. `*.tfvars`, `.env`, credentials, keys are git-ignored; commit
  `*.example` templates instead.

## Before committing

`pre-commit` runs fmt/lint/security automatically. Run `make hooks` once to enable.
Don't bypass hooks with `--no-verify`.
