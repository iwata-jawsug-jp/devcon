SHELL := /bin/bash
.DEFAULT_GOAL := help

INFRA_DIR     := infra
BOOTSTRAP_DIR := infra/bootstrap
BACKEND_DIR   := services/backend/python
FRONTEND_DIR  := services/frontend

.PHONY: help setup hooks check-setup dev gen-types gen-design-tokens fmt lint test security perf-test ci-frontend \
        db-up db-down migrate makemigration \
        tf-init tf-fmt tf-validate tf-plan tf-lint check-iam-policies \
        backend-setup backend-dev backend-test backend-lint \
        frontend-setup frontend-dev frontend-build frontend-lint frontend-test frontend-test-e2e \
        metrics-dora-lint metrics-dora-test check-oauth-scopes

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## ---- Bootstrap ----
setup: backend-setup frontend-setup hooks ## Install all toolchains + git hooks

hooks: ## Install pre-commit git hooks
	pip install --quiet pre-commit || python3 -m pip install --quiet pre-commit
	pre-commit install

check-setup: ## Check dev environment initial setup (tools, logins, make setup)
	./tools/script/check-devenv-setup.sh

## ---- Run locally ----
dev: db-up ## Run backend (:8000) and frontend (:5173) together (starts the db first)
	@echo "backend → http://localhost:8000/docs   frontend → http://localhost:5173   (Ctrl-C to stop)"
	@trap 'kill 0' INT TERM EXIT; \
		( cd $(BACKEND_DIR) && uv run uvicorn api.main:app --reload --port 8000 ) & \
		( cd $(FRONTEND_DIR) && npm run dev ) & \
		wait

gen-types: ## Generate frontend TS types from the API OpenAPI schema
	cd $(BACKEND_DIR) && uv run python -c "import json,sys; from api.main import app; json.dump(app.openapi(), sys.stdout)" > $(CURDIR)/$(FRONTEND_DIR)/openapi.json
	cd $(FRONTEND_DIR) && npx --yes openapi-typescript openapi.json -o src/api/schema.ts
	rm -f $(FRONTEND_DIR)/openapi.json

gen-design-tokens: ## Regenerate src/main.css's @theme block from docs/frontend-design.md (DESIGN.md)
	cd $(FRONTEND_DIR) && npm run design:gen-theme
	cd $(FRONTEND_DIR) && npx prettier --write src/main.css

## ---- Database ----
db-up: ## Start the local Postgres container (detached)
	docker compose up -d db

db-down: ## Stop and remove local containers
	docker compose down

migrate: ## Apply Alembic migrations (alembic upgrade head)
	cd $(BACKEND_DIR) && uv run alembic upgrade head

makemigration: ## Autogenerate a migration: make makemigration m="message"
	cd $(BACKEND_DIR) && uv run alembic revision --autogenerate -m "$(m)"

## ---- Aggregate ----
fmt: tf-fmt ## Format everything
	cd $(BACKEND_DIR) && uv run ruff format .
	cd $(FRONTEND_DIR) && npm run format

lint: tf-lint backend-lint frontend-lint metrics-dora-lint check-oauth-scopes ## Lint everything

test: backend-test frontend-test metrics-dora-test ## Run all unit tests (backend pytest + frontend vitest + metrics unittest)

# checkov is informational (--soft-fail) in all three gates (pre-commit / make / CI) —
# remaining findings (WAF, Multi-AZ RDS, KMS CMKs, custom-domain HTTPS, access logging, ...)
# are deliberate cost/scope trade-offs for this dev-tier stack. See issue #111.
security: ## Run Trivy + Checkov over infra (same severity/soft-fail as pre-commit and CI)
	trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore $(INFRA_DIR)
	checkov -d $(INFRA_DIR) --quiet --compact --soft-fail

## ---- Perf (Issue #43; not part of the PR-blocking CI gate — see .github/workflows/perf.yml) ----
perf-test: ## Run the k6 load/perf smoke test against a local uvicorn instance (needs k6 on PATH, Postgres via `make db-up`)
	cd $(BACKEND_DIR) && uv run alembic upgrade head
	cd $(BACKEND_DIR) && ( uv run uvicorn perf.app:app --host 127.0.0.1 --port 8000 & echo $$! > /tmp/devcon-perf-app.pid )
	@for i in $$(seq 1 20); do curl -sf http://127.0.0.1:8000/api/health > /dev/null && break; sleep 0.5; done
	k6 run perf/k6/items-smoke.js; \
		status=$$?; \
		kill "$$(cat /tmp/devcon-perf-app.pid)" 2>/dev/null; \
		rm -f /tmp/devcon-perf-app.pid; \
		exit $$status

ci-frontend: ## Reproduce the CI frontend job locally (mirrors ci.yml step order)
	cd $(FRONTEND_DIR) && npm run lint
	cd $(FRONTEND_DIR) && npx vue-tsc --noEmit
	cd $(FRONTEND_DIR) && npm run design:lint
	cd $(FRONTEND_DIR) && npm test
	cd $(FRONTEND_DIR) && npm run build
	cd $(FRONTEND_DIR) && npm run check:bundle-budget
	cd $(FRONTEND_DIR) && \
		if [ -z "$$CHROME_PATH" ] && ! command -v google-chrome >/dev/null 2>&1 \
			&& ! command -v google-chrome-stable >/dev/null 2>&1 \
			&& ! command -v chromium >/dev/null 2>&1 \
			&& ! command -v chromium-browser >/dev/null 2>&1; then \
			CHROME_PATH="$$(node -e 'console.log(require("@playwright/test").chromium.executablePath())')"; \
			export CHROME_PATH; \
			echo "lhci: no Chrome found — falling back to Playwright chromium: $$CHROME_PATH"; \
		fi; \
		npx lhci autorun
	cd $(FRONTEND_DIR) && npm run test:e2e

## ---- Terraform ----
tf-init: ## terraform init (app layer; pass BACKEND=env/<env>.backend.hcl for remote state)
	cd $(INFRA_DIR) && terraform init $$( [ -n "$(BACKEND)" ] && echo -backend-config=$(BACKEND) )

tf-fmt: ## terraform fmt
	terraform fmt -recursive $(INFRA_DIR)

tf-validate: ## terraform validate
	cd $(INFRA_DIR) && terraform validate

tf-plan: ## terraform plan (uses env/dev.tfvars if present)
	cd $(INFRA_DIR) && terraform plan $$( [ -f env/dev.tfvars ] && echo -var-file=env/dev.tfvars )

tf-lint: ## tflint --recursive over infra (same command as CI)
	cd $(INFRA_DIR) && tflint --init --config=$(CURDIR)/.tflint.hcl \
		&& tflint --recursive --config=$(CURDIR)/.tflint.hcl

check-iam-policies: ## Validate infra/bootstrap's current IAM policies via accessanalyzer (#340; needs local AWS credentials, not part of `make lint`/`make security` -- see docs/infrastructure.md)
	cd $(BOOTSTRAP_DIR) && terraform show -json terraform.tfstate > /tmp/bootstrap-iam-plan.json
	python3 .github/scripts/check_iam_policies.py /tmp/bootstrap-iam-plan.json

## ---- Backend (services/backend/python, FastAPI) ----
backend-setup: ## uv sync (install deps)
	cd $(BACKEND_DIR) && uv sync

backend-dev: ## uvicorn --reload on :8000
	cd $(BACKEND_DIR) && uv run uvicorn api.main:app --reload --port 8000

backend-test: ## pytest
	cd $(BACKEND_DIR) && uv run pytest

backend-lint: ## ruff check + mypy
	cd $(BACKEND_DIR) && uv run ruff check . && uv run mypy

## ---- Frontend (services/frontend, Vite + Vue 3) ----
frontend-setup: ## npm install
	cd $(FRONTEND_DIR) && npm install

frontend-dev: ## vite dev server on :5173
	cd $(FRONTEND_DIR) && npm run dev

frontend-build: ## vue-tsc + vite build
	cd $(FRONTEND_DIR) && npm run build

frontend-lint: ## eslint + vue-tsc typecheck + design.md lint
	cd $(FRONTEND_DIR) && npm run lint && npm run typecheck && npm run design:lint

frontend-test: ## vitest unit tests
	cd $(FRONTEND_DIR) && npm test

frontend-test-e2e: ## playwright e2e tests
	cd $(FRONTEND_DIR) && npm run test:e2e

## ---- Metrics (.github/scripts, stdlib-only) ----
# ruff version pinned here MUST match .pre-commit-config.yaml's rev (ruff-pre-commit) —
# not services/backend/python's uv-managed ruff, which pins independently and would drift.
METRICS_RUFF_VERSION := 0.11.13

metrics-dora-lint: ## ruff check + format --check over .github/scripts
	python3 -m pip install --quiet "ruff==$(METRICS_RUFF_VERSION)"
	python3 -m ruff check .github/scripts
	python3 -m ruff format --check .github/scripts

metrics-dora-test: ## Run the DORA metrics script's unit tests
	cd .github/scripts && python3 -m unittest discover -s tests -t . -v

check-oauth-scopes: ## Cross-check infra/auth.tf resource-server scopes against oidcConfig.ts's login scope list (#438)
	python3 .github/scripts/check_oauth_scopes.py
