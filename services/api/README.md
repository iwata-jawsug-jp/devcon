# api (FastAPI service)

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

## Quality

```bash
uv run pytest                       # tests
uv run ruff check . && uv run mypy  # lint + type check
```

## Configuration

Settings are read from `API_*` environment variables (or a local `.env`).
See [.env.example](./.env.example).
