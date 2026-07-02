"""Shared pytest fixtures: async DB engine, session, and HTTP client."""

import os
from collections.abc import AsyncIterator
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import StaticPool

from api.db.base import Base
from api.db.session import get_session
from api.main import app

TEST_DATABASE_URL = os.getenv("TEST_DATABASE_URL", "sqlite+aiosqlite:///:memory:")


@pytest.fixture
async def session() -> AsyncIterator[AsyncSession]:
    """Create a fresh schema on an isolated engine and yield a session."""
    engine_kwargs: dict[str, Any] = {}
    if TEST_DATABASE_URL.startswith("sqlite"):
        # Share a single in-memory connection so the schema is visible everywhere.
        engine_kwargs["poolclass"] = StaticPool
        engine_kwargs["connect_args"] = {"check_same_thread": False}

    engine = create_async_engine(TEST_DATABASE_URL, **engine_kwargs)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    factory = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    async with factory() as db_session:
        yield db_session

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest.fixture
async def client(session: AsyncSession) -> AsyncIterator[AsyncClient]:
    """Yield an HTTP client whose ``get_session`` dependency uses the test session."""

    async def override_get_session() -> AsyncIterator[AsyncSession]:
        yield session

    app.dependency_overrides[get_session] = override_get_session
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as http_client:
        yield http_client
    app.dependency_overrides.pop(get_session, None)
