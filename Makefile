SHELL := /bin/bash
.DEFAULT_GOAL := help

INFRA_DIR     := infra
BOOTSTRAP_DIR := infra/bootstrap
API_DIR       := services/api
WEB_DIR       := services/web

.PHONY: help setup hooks dev gen-types fmt lint test security \
        tf-init tf-fmt tf-validate tf-plan tf-lint \
        api-setup api-dev api-test api-lint \
        web-setup web-dev web-build web-lint web-test web-test-e2e

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## ---- Bootstrap ----
setup: api-setup web-setup hooks ## Install all toolchains + git hooks

hooks: ## Install pre-commit git hooks
	pip install --quiet pre-commit || python3 -m pip install --quiet pre-commit
	pre-commit install

## ---- Run locally ----
dev: ## Run api (:8000) and web (:5173) together
	@echo "api → http://localhost:8000/docs   web → http://localhost:5173   (Ctrl-C to stop)"
	@trap 'kill 0' INT TERM EXIT; \
		( cd $(API_DIR) && uv run uvicorn api.main:app --reload --port 8000 ) & \
		( cd $(WEB_DIR) && npm run dev ) & \
		wait

gen-types: ## Generate web TS types from the API OpenAPI schema
	cd $(API_DIR) && uv run python -c "import json,sys; from api.main import app; json.dump(app.openapi(), sys.stdout)" > $(CURDIR)/$(WEB_DIR)/openapi.json
	cd $(WEB_DIR) && npx --yes openapi-typescript openapi.json -o src/api/schema.ts
	rm -f $(WEB_DIR)/openapi.json

## ---- Aggregate ----
fmt: tf-fmt ## Format everything
	cd $(API_DIR) && uv run ruff format .
	cd $(WEB_DIR) && npm run format

lint: tf-lint api-lint web-lint ## Lint everything

test: api-test web-test ## Run all unit tests (api pytest + web vitest)

security: ## Run Trivy + Checkov over infra
	trivy config $(INFRA_DIR)
	checkov -d $(INFRA_DIR) --quiet --compact

## ---- Terraform ----
tf-init: ## terraform init (app layer; pass BACKEND=env/<env>.backend.hcl for remote state)
	cd $(INFRA_DIR) && terraform init $$( [ -n "$(BACKEND)" ] && echo -backend-config=$(BACKEND) )

tf-fmt: ## terraform fmt
	terraform fmt -recursive $(INFRA_DIR)

tf-validate: ## terraform validate
	cd $(INFRA_DIR) && terraform validate

tf-plan: ## terraform plan (uses env/dev.tfvars if present)
	cd $(INFRA_DIR) && terraform plan $$( [ -f env/dev.tfvars ] && echo -var-file=env/dev.tfvars )

tf-lint: ## tflint
	cd $(INFRA_DIR) && tflint --init && tflint --config=$(CURDIR)/.tflint.hcl

## ---- Python API (services/api, FastAPI) ----
api-setup: ## uv sync (install deps)
	cd $(API_DIR) && uv sync

api-dev: ## uvicorn --reload on :8000
	cd $(API_DIR) && uv run uvicorn api.main:app --reload --port 8000

api-test: ## pytest
	cd $(API_DIR) && uv run pytest

api-lint: ## ruff check + mypy
	cd $(API_DIR) && uv run ruff check . && uv run mypy

## ---- Web SPA (services/web, Vite + Vue 3) ----
web-setup: ## npm install
	cd $(WEB_DIR) && npm install

web-dev: ## vite dev server on :5173
	cd $(WEB_DIR) && npm run dev

web-build: ## vue-tsc + vite build
	cd $(WEB_DIR) && npm run build

web-lint: ## eslint + vue-tsc typecheck
	cd $(WEB_DIR) && npm run lint && npm run typecheck

web-test: ## vitest unit tests
	cd $(WEB_DIR) && npm test

web-test-e2e: ## playwright e2e tests
	cd $(WEB_DIR) && npm run test:e2e
