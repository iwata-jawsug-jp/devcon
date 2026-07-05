# syntax=docker/dockerfile:1
# Production image for the FastAPI service. Built & pushed by .github/workflows/cd-app.yml.
FROM python:3.14-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

# uv for fast, reproducible installs (pinned binary from the official image)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install dependencies first (cached unless the lockfile changes).
# README.md is copied too because pyproject.toml references it (project build).
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project

# App source + Alembic config/migrations, then install the project itself.
COPY src ./src
COPY alembic.ini ./
COPY alembic ./alembic
RUN uv sync --frozen --no-dev

EXPOSE 8000
# --no-sync: the venv is already built; never reach the network at runtime
# (Fargate tasks run in private subnets with no internet egress).
# --no-access-log: uvicorn's own (plain-text) access log would duplicate the
# JSON one CorrelationIdMiddleware already emits (api/middleware.py, #42).
CMD ["uv", "run", "--no-sync", "uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
