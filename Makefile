SHELL := /bin/bash
.DEFAULT_GOAL := help

INFRA_DIR      := infra
BACKEND_DIR    := services/backend/python
BACKEND_GO_DIR := services/backend/go
FRONTEND_DIR   := services/frontend

.PHONY: help setup hooks check-setup check-repo-vars claude-setup dev gen-types gen-schema gen-design-tokens fmt lint test security perf-test ci-frontend \
        db-up db-down migrate makemigration \
        tf-init tf-fmt tf-validate tf-plan tf-lint policy-test policy-test-bootstrap \
        backend-setup backend-dev backend-test backend-lint \
        backend-go-setup backend-go-dev backend-go-test backend-go-lint \
        frontend-setup frontend-dev frontend-build frontend-lint frontend-test frontend-test-e2e \
        metrics-dora-lint metrics-dora-test check-oauth-scopes scaffold-verify

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## ---- Bootstrap ----
setup: backend-setup backend-go-setup frontend-setup hooks ## Install all toolchains + git hooks

hooks: ## Install pre-commit git hooks
	pip install --quiet pre-commit || python3 -m pip install --quiet pre-commit
	pre-commit install

check-setup: ## Check dev environment initial setup (tools, logins, make setup)
	bash tools/script/check-devenv-setup.sh

check-repo-vars: ## Cross-check repository variables: workflow refs vs docs vs actually registered
	bash tools/script/check-repo-vars.sh

claude-setup: ## GitHub Codespaces: Claude Code のオンボーディング/信頼ダイアログを事前承認（新規 Codespace 作成直後、初回 claude 起動前に実行）
	bash tools/script/claude-codespaces-setup.sh

## ---- Run locally ----
dev: db-up ## Run backend (:8000) and frontend (:5173) together (starts the db first)
	@echo "backend → http://localhost:8000/docs   frontend → http://localhost:5173   (Ctrl-C to stop)"
	@trap 'kill 0' INT TERM EXIT; \
		( cd $(BACKEND_DIR) && uv run uvicorn api.main:app --reload --port 8000 ) & \
		( cd $(FRONTEND_DIR) && npm run dev ) & \
		wait

gen-types: ## Generate frontend TS types from both backends' OpenAPI schemas (Python + Go, #638)
	cd $(BACKEND_DIR) && uv run python -c "import json,sys; from api.main import app; json.dump(app.openapi(), sys.stdout)" > $(CURDIR)/$(FRONTEND_DIR)/openapi.python.json
	cd $(BACKEND_GO_DIR) && go run ./cmd/api openapi > $(CURDIR)/$(FRONTEND_DIR)/openapi.go.json
	cd $(FRONTEND_DIR) && npx --yes openapi-typescript openapi.python.json -o src/api/schema.python.ts
	cd $(FRONTEND_DIR) && npx --yes openapi-typescript openapi.go.json -o src/api/schema.go.ts
	rm -f $(FRONTEND_DIR)/openapi.python.json $(FRONTEND_DIR)/openapi.go.json

# #639 (proposal §2.3.1): Alembic (services/backend/python) is the sole schema authority — Go
# never migrates. This snapshots the migrated schema for sqlc to read. pg_dump 16.10+ wraps
# output in psql-only `\restrict`/`\unrestrict` guard commands (not valid SQL); strip them so
# the file stays plain DDL that both sqlc's parser and a raw `psql -f` can consume.
gen-schema: db-up migrate ## Snapshot the Alembic-migrated schema for Go's sqlc (Go never migrates; #639)
	docker compose exec -T db pg_dump -U app -d app --schema-only --no-owner --no-privileges \
		| sed '/^\\restrict /d; /^\\unrestrict /d' > $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql
	printf '%s\n' "$$(cat $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql)" > $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql.tmp
	mv $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql.tmp $(CURDIR)/$(BACKEND_GO_DIR)/internal/db/schema.sql
	cd $(BACKEND_GO_DIR) && sqlc generate

gen-design-tokens: ## Regenerate src/main.css's @theme block from docs/frontend-design.md (DESIGN.md)
	cd $(FRONTEND_DIR) && npm run design:gen-theme
	cd $(FRONTEND_DIR) && npx prettier --write src/main.css

## ---- Database ----
db-up: ## Start the local Postgres container (detached, blocks until its healthcheck passes)
	docker compose up -d --wait db

db-down: ## Stop and remove local containers
	docker compose down

migrate: ## Apply Alembic migrations (alembic upgrade head)
	cd $(BACKEND_DIR) && uv run alembic upgrade head

makemigration: ## Autogenerate a migration: make makemigration m="message"
	cd $(BACKEND_DIR) && uv run alembic revision --autogenerate -m "$(m)"

## ---- Aggregate ----
fmt: tf-fmt ## Format everything
	cd $(BACKEND_DIR) && uv run ruff format .
	cd $(BACKEND_GO_DIR) && golangci-lint fmt
	cd $(FRONTEND_DIR) && npm run format

lint: tf-lint policy-test backend-lint backend-go-lint frontend-lint metrics-dora-lint check-oauth-scopes ## Lint everything

test: backend-test backend-go-test frontend-test metrics-dora-test ## Run all unit tests (backend pytest + backend-go go test + frontend vitest + metrics unittest)

# checkov is informational (--soft-fail) in all three gates (pre-commit / make / CI) —
# remaining findings (WAF, Multi-AZ RDS, KMS CMKs, custom-domain HTTPS, access logging, ...)
# are deliberate cost/scope trade-offs for this dev-tier stack. See issue #111.
# govulncheck (services/backend/go) mirrors these two: same severity stance (no soft-fail —
# a known-vulnerable dependency blocks, same as Trivy's HIGH,CRITICAL over infra).
security: ## Run Trivy + Checkov over infra, govulncheck over services/backend/go (same as pre-commit and CI)
	trivy config --severity HIGH,CRITICAL --ignorefile .trivyignore $(INFRA_DIR)
	checkov -d $(INFRA_DIR) --quiet --compact --soft-fail
	cd $(BACKEND_GO_DIR) && govulncheck ./...

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

# Rego unit tests only (#296, ADR-0017) -- no AWS credentials needed, so this is what
# pre-commit/ci.yml run. `conftest test` against a real app-layer plan happens in
# cd-infra.yml's plan job (it needs the AWS plan role); for the bootstrap layer, see
# policy-test-bootstrap below.
policy-test: ## conftest verify (Rego policy unit tests, same command as CI)
	conftest verify --policy $(INFRA_DIR)/policy

# infra/bootstrap is applied by hand with local state (docs/infrastructure.md), so neither
# this repo's CI nor a fresh clone has state to plan it against -- which is why `conftest
# test` did not cover it until #657, and the ci_deploy policies could violate
# iam_wildcard.rego / region_condition.rego with CI still green.
#
# Plan it from an *empty* state with synthetic variables instead: every rule here inspects
# only the shape of the rendered documents (wildcard actions, region conditions, required
# tags), which does not depend on the real project name, account or suffix. Runs in a temp
# copy so it can never disturb the operator's real infra/bootstrap state or leave a tfplan
# behind. Needs AWS credentials (data.aws_caller_identity / data.aws_kms_alias); cd-infra.yml's
# plan job calls this same target with the read-only plan role.
policy-test-bootstrap: ## conftest test against a synthetic infra/bootstrap plan (needs AWS creds; same command as CI)
	@set -euo pipefail; \
	work="$$(mktemp -d)"; \
	trap 'rm -rf "$$work"' EXIT; \
	cp $(INFRA_DIR)/bootstrap/*.tf "$$work/"; \
	cd "$$work"; \
	TF_VAR_project=policycheck \
	TF_VAR_aws_region=$${AWS_REGION:-ap-northeast-1} \
	TF_VAR_github_org=policycheck-org \
	TF_VAR_github_repo=policycheck-repo \
	TF_VAR_state_bucket_name=policycheck-tfstate-placeholder \
	TF_VAR_resource_name_suffix=policy \
	sh -c 'terraform init -backend=false -input=false >/dev/null && \
	       terraform plan -no-color -input=false -out=tfplan >/dev/null && \
	       terraform show -json tfplan > bootstrap-plan.json'; \
	conftest test --policy $(CURDIR)/$(INFRA_DIR)/policy bootstrap-plan.json

## ---- Backend (services/backend/python, FastAPI) ----
backend-setup: ## uv sync (install deps)
	cd $(BACKEND_DIR) && uv sync

backend-dev: ## uvicorn --reload on :8000
	cd $(BACKEND_DIR) && uv run uvicorn api.main:app --reload --port 8000

backend-test: ## pytest
	cd $(BACKEND_DIR) && uv run pytest

backend-lint: ## ruff check + mypy
	cd $(BACKEND_DIR) && uv run ruff check . && uv run mypy

## ---- Backend (services/backend/go, Lambda-only — ADR-0024) ----
# Pin versions here match .devcontainer/Dockerfile / reusable-backend-go.yml (single
# source, same convention as TERRAFORM_VERSION etc.); update all together.
GOLANGCI_LINT_VERSION := v2.12.2
SQLC_VERSION := v1.31.1

backend-go-setup: ## go mod download + install golangci-lint/govulncheck/sqlc (idempotent)
	cd $(BACKEND_GO_DIR) && go mod download
	go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANGCI_LINT_VERSION)
	go install golang.org/x/vuln/cmd/govulncheck@latest
	go install github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)

backend-go-dev: ## air hot reload on :8000 (needs `go install github.com/air-verse/air@latest`)
	cd $(BACKEND_GO_DIR) && air

backend-go-test: ## go test ./...
	cd $(BACKEND_GO_DIR) && go test ./...

backend-go-lint: ## golangci-lint run (staticcheck + gosec + govet + errcheck + unused, .golangci.yml)
	cd $(BACKEND_GO_DIR) && golangci-lint run

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

scaffold-verify: ## Generate a project from copier.yml and verify it isn't broken (#294; needs copier on PATH)
	bash tools/script/verify-scaffold.sh
