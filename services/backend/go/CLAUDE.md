# services/backend/go — backend (Go, Lambda-only)

Loaded on demand when working in `services/backend/go/`. Root rules still apply; see
`../../../CLAUDE.md`. Full guide: `docs/proposal/go-backend-adoption-proposal.md` (decision
record) and [ADR-0024](../../../docs/adr/0024-adopt-go-as-second-backend-language.md). Nested
under `backend/` by language alongside `services/backend/python/` (ADR-0004).

## Role split with the Python backend (decided, ADR-0024)

**Python = synchronous REST (ECS Fargate). Go = asynchronous / event-driven (AWS Lambda only).**
Don't add a synchronous CRUD endpoint here just because it's convenient — that belongs in
`services/backend/python/`. Go's entry points are event triggers (SQS/EventBridge/S3) and,
longer-term, internal service-to-service calls (VPC Lattice) — see the proposal's §4.3/§5 for
the full rationale. `cmd/api/` today only proves the toolchain (healthz + `/openapi.json`);
it is not yet a public entry point.

## Stack & layout

- `go.mod` — module `github.com/iwata-jawsug-jp/devcon/services/backend/go`, Go version pinned
  via the `go`/`toolchain` directives (single source, like Python's `.python-version`).
- `cmd/api/main.go` — huma v2 (code-first OpenAPI, mirrors FastAPI's DX) on a chi router via
  `humachi`. `huma.DefaultConfig` wires `/openapi.json` / `/openapi.yaml` / `/docs`
  automatically; add operations with `huma.Register`. `go run ./cmd/api openapi` dumps the
  OpenAPI doc to stdout without starting a listener (`make gen-types` uses this).
- `cmd/worker/main.go` — the first async/event-driven entry point (#639): an aws-lambda-go
  SQS handler (`internal/worker`). Cold-start init (config → DB pool → tracing) happens once
  in `run()`; `lambda.Start` then invokes the handler per Lambda invocation. The actual
  SQS/EventBridge trigger wiring in AWS is Phase 3 (#640) — this binary only needs to behave
  correctly as a plain aws-lambda-go handler.
- DB access: pgx v5 + [sqlc](https://sqlc.dev/) generated code only (`internal/db/sqlcgen/`,
  never hand-edited) — no raw SQL in handlers (same rule as Python's repository layer) and no
  ORM. Queries live in `internal/db/queries/*.sql`; run `make gen-schema` after adding/editing
  one (it also regenerates `sqlcgen/`).
- **This service does not own the DB schema.** Migrations live in
  `services/backend/python/alembic/` (Alembic is the single authority, decided in
  proposal §2.3.1) — Go never gets its own migration tool. `make gen-schema` (`db-up` →
  `migrate` → `pg_dump --schema-only` via `docker compose exec`) snapshots the migrated
  schema into `internal/db/schema.sql` for sqlc to read, then runs `sqlc generate`; CI fails
  if either drifts from what Alembic actually produces. `pg_dump` 16.10+ wraps its output in
  psql-only `\restrict`/`\unrestrict` guard commands — the Makefile target strips them so the
  file stays plain DDL (sqlc's parser doesn't understand psql meta-commands).
- Logging: stdlib `log/slog` with a JSON handler (`internal/observability.NewLogger`) — same
  "structured logs, not `print`/`fmt.Println`" rule as Python's `logging_config.py`.
  `internal/observability.WithCorrelationID`/`LoggerFromContext` attach a per-invocation
  correlation ID (and the active span's trace/span IDs, if tracing is enabled) to every log
  line — the context-passed equivalent of Python's `request_id` contextvar (no package-level
  mutable state, per the convention below).
- Tracing: OpenTelemetry Go SDK, OTLP/gRPC, off by default
  (`internal/config.Settings.OtelTracesEnabled`) — mirrors Python's `tracing.py` (ADR-0007).
  `internal/observability.ConfigureTracing` returns a `Flush` func that **must** be called at
  the end of every Lambda invocation (`cmd/worker/main.go` does this): Lambda can freeze the
  execution environment between invocations, so — unlike a long-running server — spans can't
  rely on the batch processor's background export alone.
- Config: `internal/config` binds env vars into a `Settings` struct via `caarlos0/env`
  (Pydantic-settings equivalent) — no `API_`/`WORKER_` prefix (Go has its own service
  boundary, same as `PORT` in `cmd/api`).

## Commands

- `make backend-go-dev` — [air](https://github.com/air-verse/air) hot reload on `:8000`
- `make backend-go-lint` — `golangci-lint run` (staticcheck + gosec + gofmt, `.golangci.yml`)
- `make backend-go-test` — `go test ./...` (the `internal/worker` tests need a running
  Postgres — `make db-up` — and apply `internal/db/schema.sql` directly to a throwaway
  database, never depending on Alembic having actually run)
- `make backend-go-setup` — installs golangci-lint/govulncheck/sqlc via `go install`
- `make gen-schema` (repo root) — regenerate `internal/db/schema.sql` + `sqlcgen/` after an
  Alembic migration or a query change
- `gofmt`/`go vet` run as part of `make fmt`/`make lint`; `govulncheck` runs as part of
  `make security`

## Conventions

- Keep `net/http` (`http.Handler`) compatibility everywhere — this is what lets the same
  binary run unmodified behind [Lambda Web Adapter](https://github.com/aws/aws-lambda-web-adapter)
  (external HTTP entry points) and as a plain server locally/in ECS-style testing. Don't
  introduce a framework that requires its own non-standard server loop.
- External HTTP entry points → Lambda Web Adapter. Event-driven entry points (SQS/EventBridge/
  S3) → `aws-lambda-go` native handlers, not huma (huma is for the HTTP surface only).
- Validate request **and** response bodies with huma's typed `Body` structs (tagged with
  `json`/`example`/`doc`), not raw `map[string]any` — same spirit as Python's Pydantic models.
- No package-level mutable state; pass dependencies explicitly (constructor params), same
  reasoning as Python's `Depends()` — keeps `newAPI()`-style construction testable via
  `httptest` without a real network listener (see `cmd/api/main_test.go`).
- Config from env vars, no `API_` prefix requirement carried over from Python (Go has its own
  service boundary) but same rule: secrets stay server-side (SSM / Secrets Manager), never
  committed. `PORT` selects the listen port (default `8000`).
- Deploy target is **AWS Lambda only** (`provided.al2023`, arm64) — never add Terraform/ECS
  wiring for this service; that would duplicate the Python backend's role. `Dockerfile` here
  builds the Lambda container image (multistage, `CGO_ENABLED=0`, arm64, LWA layer copied in
  — proposal §3.2), not an ECS task image.

## API contract → frontend types

`/openapi.json` (served by huma) is this service's contract, on equal footing with the Python
backend's. `make gen-types` merges both services' OpenAPI documents into a single generated
frontend client — never hand-write those types, and never assume only the Python schema feeds
`make gen-types` (both do, decided in the proposal §7).
