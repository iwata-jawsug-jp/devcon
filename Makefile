SHELL := /bin/bash
.DEFAULT_GOAL := help

INFRA_DIR := infra
API_DIR   := services/api
WEB_DIR   := services/web

.PHONY: help setup hooks fmt lint test security \
        tf-init tf-fmt tf-validate tf-plan tf-lint \
        api-setup api-test api-lint \
        web-setup web-build web-lint web-test

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## ---- Bootstrap ----
setup: api-setup web-setup hooks ## Install all toolchains + git hooks

hooks: ## Install pre-commit git hooks
	pip install --quiet pre-commit || python3 -m pip install --quiet pre-commit
	pre-commit install

## ---- Aggregate ----
fmt: tf-fmt ## Format everything
	cd $(API_DIR) && uv run ruff format .
	cd $(WEB_DIR) && npm run format

lint: tf-lint api-lint web-lint ## Lint everything

test: api-test web-test ## Run all tests

security: ## Run Trivy + Checkov over infra
	trivy config $(INFRA_DIR)
	checkov -d $(INFRA_DIR) --quiet --compact

## ---- Terraform ----
tf-init: ## terraform init
	cd $(INFRA_DIR) && terraform init

tf-fmt: ## terraform fmt
	terraform fmt -recursive $(INFRA_DIR)

tf-validate: ## terraform validate
	cd $(INFRA_DIR) && terraform validate

tf-plan: ## terraform plan (uses env/dev.tfvars if present)
	cd $(INFRA_DIR) && terraform plan $$( [ -f env/dev.tfvars ] && echo -var-file=env/dev.tfvars )

tf-lint: ## tflint
	cd $(INFRA_DIR) && tflint --init && tflint --config=$(CURDIR)/.tflint.hcl

## ---- Python (services/api) ----
api-setup: ## uv sync (install deps)
	cd $(API_DIR) && uv sync

api-test: ## pytest
	cd $(API_DIR) && uv run pytest

api-lint: ## ruff check + mypy
	cd $(API_DIR) && uv run ruff check . && uv run mypy

## ---- Node (services/web) ----
web-setup: ## npm install
	cd $(WEB_DIR) && npm install

web-build: ## tsc build
	cd $(WEB_DIR) && npm run build

web-lint: ## eslint + typecheck
	cd $(WEB_DIR) && npm run lint && npm run typecheck

web-test: ## node --test
	cd $(WEB_DIR) && npm test
