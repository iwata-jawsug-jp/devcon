# services/api — backend (Python, FastAPI)

Loaded on demand when working in `services/api/`. Root rules still apply; see
`../../CLAUDE.md`. Full guide: `docs/app-development.md`.

## Stack & layout

uv-managed (`pyproject.toml`, `src/api`, `tests/`). FastAPI `app` in `src/api/main.py`;
routers in `routers/`, Pydantic models in `schemas/`, settings in `config.py`
(`pydantic-settings`). DB layer in `db/` (SQLAlchemy `Base`, async engine/session, ORM
models), data access in `repositories/`, migrations in `alembic/`.

## Commands (use `uv run`, never bare `python`/`pip`)

- `uv run uvicorn api.main:app --reload` — dev server (:8000); docs at /docs
- `uv run pytest` · `uv run ruff check .` · `uv run mypy`
- DB: `make db-up` · `make migrate` (alembic upgrade head) · `make makemigration m="..."`

## Conventions

- Async route handlers. Inject dependencies with `Depends`.
- Validate request **and** response bodies with Pydantic models, not raw dicts; set
  `response_model=`. Routes live under the `/api` prefix.
- ruff (line length 100, `py312`), mypy strict — keep type hints.
- **No raw SQL in routers/handlers.** Get an `AsyncSession` via `Depends(get_session)` and
  go through a repository.
- **Every schema change is an Alembic migration** (`make makemigration`); never edit the DB
  by hand. ORM models are `Mapped[...]`-typed; keep Pydantic (API I/O) and ORM models
  separate (response models use `from_attributes=True`).
- Tests default to in-memory SQLite (aiosqlite) and run against Postgres in CI.
- Config from env vars (`API_`-prefixed). Backend secrets stay server-side (SSM / Secrets
  Manager); never commit them.

## API contract → frontend types

FastAPI's OpenAPI schema (`/openapi.json`) is the single source of truth. After changing
request/response shapes, regenerate the TS client with `make gen-types` — never hand-write
those types in two places.
