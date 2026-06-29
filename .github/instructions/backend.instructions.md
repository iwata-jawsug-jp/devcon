---
applyTo: 'services/api/**'
---

# Backend (Python / FastAPI)

Details: `docs/app-development.md`, `services/api/CLAUDE.md`.

- Always run Python via `uv run`. Never use bare `python` / `pip`.
- Route handlers are async. Inject dependencies with `Depends`.
- Validate both request and response with Pydantic models and set
  `response_model=`. Don't return raw dicts. Routes live under the `/api` prefix.
- No raw SQL in handlers/routers. Get an `AsyncSession` via
  `Depends(get_session)` and go through a repository (separation of concerns).
- Every schema change is an Alembic migration (`make makemigration`); never edit
  the DB by hand. Keep ORM and Pydantic models separate (responses use
  `from_attributes=True`).
- Keep type hints (mypy strict).
- Read config from `API_`-prefixed env vars. Backend secrets stay server-side
  (SSM / Secrets Manager); never commit them.
- After changing request/response shapes, regenerate the TS client with
  `make gen-types`. Don't hand-write those types twice.
