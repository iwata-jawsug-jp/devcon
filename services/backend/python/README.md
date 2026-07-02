# backend/python (FastAPI service)

Backend REST API for the web app, built with [FastAPI](https://fastapi.tiangolo.com/)
and served by [uvicorn](https://www.uvicorn.org/). Managed with
[uv](https://docs.astral.sh/uv/).

## Develop

```bash
uv sync                                   # install deps (incl. dev group)
uv run uvicorn api.main:app --reload      # run the dev server on :8000
```

- Interactive docs: http://localhost:8000/docs
- OpenAPI schema: http://localhost:8000/openapi.json

## API

All routes are served under the `/api` prefix.

- `GET /api/health` → `{"status": "ok"}`
- `GET /api/items` → list of items
- `GET /api/items/{item_id}` → an item, or 404 if not found
- `POST /api/items` → 201 with the created item

## Database

The service uses **PostgreSQL** via SQLAlchemy 2.0 (async, `asyncpg`) with Alembic
migrations.

```bash
make db-up                          # start local Postgres (docker compose, :5432)
make migrate                        # alembic upgrade head
make makemigration m="add x table"  # autogenerate a new revision
make db-down                        # stop the database
```

The connection string is read from `API_DATABASE_URL`
(default `postgresql+asyncpg://app:app@localhost:5432/app`).

## Quality

```bash
uv run pytest                       # tests
uv run ruff check . && uv run mypy  # lint + type check
```

Tests are database-agnostic: they default to an in-memory **SQLite**
(`sqlite+aiosqlite`) database and create the schema directly from the ORM
metadata (no Alembic), so they run anywhere. Set `TEST_DATABASE_URL` to a
Postgres URL (as CI does) to exercise the real engine.

## Configuration

Settings are read from `API_*` environment variables (or a local `.env`).
See [.env.example](./.env.example).
