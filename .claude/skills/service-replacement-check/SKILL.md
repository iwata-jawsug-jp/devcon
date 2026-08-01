---
name: service-replacement-check
description: Diagnose whether a services/backend/<lang>/ or services/frontend/ replacement (a different language/framework than the current Python/FastAPI or Vue/Vite implementation) satisfies the infra/CI contract, or plan one before writing code. Use reactively after building a new implementation to audit it against the contract, or proactively before starting to walk through the judgment criteria and produce a concrete touch-point checklist.
allowed-tools: Read, Grep, Glob, Bash
argument-hint: <path to new implementation> | <target language/framework + role: backend|frontend>
---

# service-replacement-check

## Overview

`docs/proposal/service-replacement-proposal.md` documents that swapping `services/backend/python`
or `services/frontend` for a different language/framework is obstructed less by the application
code itself than by an implicit contract scattered across `infra/*.tf`, `.github/workflows/*.yml`,
and `Makefile` — six Dockerfile-level requirements, four infra values, and a frontend quality-gate
parity requirement. Most of these are not mechanically greppable (e.g. "does this Dockerfile
resolve dependencies at build time only" requires reading and reasoning about the file, not a
regex), which is why this is a Claude Code skill rather than a CI script — the same split this
repo already uses for `ci-deploy-iam-gap` (judgment-heavy diagnosis) vs. `check_adr_audience.py`
(mechanical drift check).

This skill checks *whether* a replacement satisfies the contract (Mode A) or *what* it needs to
touch (Mode B). For the step-by-step "how" — which file, which line, what to change it to — see
`docs/service-replacement-guide.md`, the practical companion this skill's checklist rows map onto.

## When to Use

- **Mode A (reactive):** a new backend or frontend implementation (in-progress or complete)
  exists and needs to be checked against the contract before it's considered ready to deploy.
- **Mode B (proactive):** before writing any code, to decide whether the replacement is
  well-scoped (per the judgment criteria below) and get a concrete list of every file/line that
  will need touching.

Do not use this skill to pick *which* language/framework to replace with — that decision is
explicitly out of scope for `docs/proposal/service-replacement-proposal.md` §5 and stays a human
call informed by the "候補言語での検証" table in that proposal (§4.4) as prior art, not a rule this
skill enforces.

## Inputs

- Mode A: the path to the new implementation directory (e.g. `services/backend/java/`,
  `services/frontend/` if already replaced in place).
- Mode B: the target role (`backend` or `frontend`) and candidate language/framework.

## Judgment criteria (Mode B, before starting)

Borrowed from `docs/proposal/backend-language-extensibility-proposal.md` §4.1 (the "addition"
criteria) and generalized to "replacement" by `service-replacement-proposal.md` §4.5:

1. **Role differentiation**: for a *backend* replacement, does the new implementation keep the
   same role split as today (sync REST = this service, async/event-driven = `services/backend/go`
   if it still exists)? Changing the role split is a bigger decision than a language swap and
   should be its own ADR, not folded into this one.
2. **Execution platform**: does it stay on the platform the role already implies (ECS Fargate for
   sync REST, Lambda for async) rather than introducing a new platform for no reason tied to the
   language itself?
3. **Schema authority**: if this replacement *removes* Python while `services/backend/go` (or any
   other consumer of `Makefile`'s `gen-schema`) stays, the schema authority currently held by
   Alembic must move somewhere before Python is deleted — flag this explicitly, don't let it be
   silently orphaned. (`service-replacement-proposal.md` §3.1 — the coupling is shallow, only the
   `migrate` step of `gen-schema` needs a new owner, not the whole pipeline.)
4. **Contract unification**: the new implementation must still produce OpenAPI JSON via a single
   command `make gen-types` can call (Go's `go run ./cmd/api openapi` is the existing pattern to
   follow), and (frontend only) must still consume that schema through generated types, never
   hand-written request/response shapes.

If any of these doesn't hold, say so plainly and ask whether the scope should grow (new ADR) before
proceeding — don't quietly stretch this skill's checklist to cover a bigger decision.

## Method — Mode A (reactive: audit an implementation)

Walk each row below against the target path. Report per-row pass/fail/not-applicable with the
concrete evidence (file:line quoted or command output), not a vibe assessment.

### Backend rows

以下の行は同期REST（`services/backend/python` 相当、ECS Fargate上の常駐HTTPサーバー）を対象と
する。非同期/イベント駆動ロール（`services/backend/go` 相当、Lambda、ADR-0024）はスコープ外
——判断が必要な場合は診断結果に明示し、この表をそのまま当てはめない。

| # | Check | How to verify |
| --- | --- | --- |
| 1 | Listens on `0.0.0.0:<configured port>`, not loopback-only | Read the app entrypoint / Dockerfile `CMD` |
| 2 | Health-check route requires no auth and returns 200 | Grep the router/auth-dependency wiring for the health route; confirm no `require_scope`-equivalent guard on it |
| 3 | All dependencies resolved at Docker build time (no runtime package installs) | Read the Dockerfile; flag any `RUN` step after the final `COPY` that hits a package registry, and any framework default that phones home at *runtime* (e.g. Next.js telemetry — `service-replacement-proposal.md` §4.4 already found this one; check for the equivalent in whatever framework this is) |
| 4 | Only calls AWS services reachable via the VPC endpoints in `infra/endpoints.tf` (S3, ECR, CloudWatch Logs, Secrets Manager, Cognito IDP, optionally X-Ray) at runtime | Grep the implementation for outbound HTTP/SDK calls; anything hitting a bare public hostname (not resolved by an endpoint) will hang, not fail fast — this bit the repo once already (#369) |
| 5 | Exposes a migration entrypoint invocable via container-command override | Confirm there's a command equivalent to `["uv","run","--no-sync","alembic","upgrade","head"]` and that `.github/workflows/reusable-app-deploy.yml`'s `containerOverrides` (currently line ~164) has been updated to it |
| 6 | Reads the literal `API_*` env var names `infra/api.tf` injects (`API_DB_HOST`, `API_DB_PORT`, `API_DB_NAME`, `API_DB_USER`, `API_DB_PASSWORD`, `API_ENVIRONMENT`, `API_OTEL_TRACES_ENABLED`, `API_COGNITO_USER_POOL_ID`, `API_COGNITO_REGION`, `API_COGNITO_CLIENT_ID`) unless `infra/api.tf` was also changed to match a different naming convention | Grep the config-loading code for each name; report any the new implementation expects under a different name |
| 7 | `infra/api.tf`'s port/health-check-path use `var.api_port`/`var.api_health_check_path`, not a literal `8000`/`"/api/health"` | `grep -n '8000\|"/api/health"' infra/api.tf` — any hit not inside a variable default is a regression |
| 8 | A `reusable-backend-<lang>.yml` exists and produces OpenAPI JSON via a single command | Check `.github/workflows/`; confirm `Makefile`'s `gen-types` target was updated to call it |

### Frontend rows

| # | Check | How to verify |
| --- | --- | --- |
| 1 | `/callback` and `/login` (or `var.auth_callback_path`/`var.auth_login_path` if the infra variabilization in §4.1 has landed) routes exist and complete the OAuth2 code exchange | Read the router config |
| 2 | Build output lands where `reusable-app-deploy.yml`'s `aws s3 sync` step expects (`dist/` today, or wherever the workflow was updated to expect) | Check the build config's output dir against the workflow |
| 3 | Consumes backend types via a generated client, never hand-written request/response shapes | Grep for the generated-client import; flag any ad-hoc `fetch`/manual type definitions for API calls |
| 4 | **Quality gate parity** (`service-replacement-proposal.md` §4.2, invariant): the new `reusable-frontend-<framework>.yml` includes type-checking, an automated a11y check, a performance-budget check, and an authenticated E2E smoke test | Read the new reusable workflow; report which of the four categories is present/missing (tool substitution is fine, category dropping is not) |
| 5 | Design tokens still source from `docs/frontend-design.md`'s front matter | Confirm the new build's token-generation step reads that file rather than hand-copied/hard-coded values (`service-replacement-proposal.md` §4.3 — the pipeline is expected to be rewritten, the *values* are not) |

## Output Format

```
## service-replacement-check report
- MODE: A (reactive) | B (proactive)
- ROLE: backend | frontend
- TARGET: <path or language/framework>
- JUDGMENT CRITERIA (Mode B only): role differentiation / execution platform / schema authority / contract unification — pass/flag each
- ROWS CHECKED: <n>/<total>, PASS: <n>, FAIL: <n>, N/A: <n>
- FAILURES: <row #> — <evidence> — <what's needed to fix it>
- VERIFIED: yes (checks ran against real files/commands) | pending (Mode B plan only, no implementation to check yet)
- RELATED: docs/proposal/service-replacement-proposal.md §<section>
```

## Common Rationalizations

| Rationalization | Reality |
| --- | --- |
| "It builds and the health check returns 200 locally, that's enough" | Local dev doesn't exercise the no-internet-egress private subnet constraint (row 3/4) — this is exactly the class of gap `#369` proves only shows up in a real deploy. |
| "The framework's docs don't mention build-time-only dependencies, so it's probably fine" | Ask explicitly whether the framework has any runtime phone-home behavior (telemetry, remote config fetch, lazy dependency resolution) — this is precisely the kind of default that's invisible until it hangs in a NAT-less subnet. |
| "I'll keep the old `API_*` env var names to save time, even though they're unidiomatic for this language" | Valid choice, but state it explicitly in row 6's report rather than silently working around it — a future reader needs to know `infra/api.tf` wasn't the piece that changed. |
| "One quality-gate tool swap is basically the same as the others" | Row 4 checks *category* presence, not tool identity — dropping a11y or perf-budget checking because the new framework's ecosystem tool is less mature is a real regression, not a wash. |
