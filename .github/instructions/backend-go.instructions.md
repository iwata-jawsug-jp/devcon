---
applyTo: 'services/backend/go/**'
---

# Backend Go (async/event-driven, Lambda-only)

Details: `docs/proposal/go-backend-adoption-proposal.md`, `services/backend/go/CLAUDE.md`.

- **Async/event-driven only** (SQS/EventBridge/S3 triggers). Don't add a
  synchronous CRUD endpoint here just because it's convenient — that belongs
  in `services/backend/python/`.
- DB access is pgx v5 + sqlc-generated code only (`internal/db/sqlcgen/`,
  never hand-edited) — no raw SQL in handlers, no ORM. Queries live in
  `internal/db/queries/*.sql`; run `make gen-schema` after adding/editing one.
- **This service does not own the DB schema.** Migrations live in
  `services/backend/python/alembic/` (Alembic is the single authority) — never
  add a migration tool here.
- Validate request/response with huma's typed `Body` structs, not raw
  `map[string]any`.
- No package-level mutable state; pass dependencies explicitly (constructor
  params).
- Logging: stdlib `log/slog` with a JSON handler, never `fmt.Println`/`print`.
- Deploy target is **AWS Lambda only** (`provided.al2023`, arm64) — never add
  Terraform/ECS wiring for this service.
- `/openapi.json` (served by huma) is this service's API contract, on equal
  footing with the Python backend's. `make gen-types` merges both services'
  OpenAPI documents — never hand-write those types.
