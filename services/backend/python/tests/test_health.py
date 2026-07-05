from collections.abc import AsyncIterator
from unittest.mock import AsyncMock

import pytest
from httpx import AsyncClient
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from api.db.session import get_session
from api.main import app


async def test_health_ok(client: AsyncClient) -> None:
    response = await client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "ok"}


@pytest.mark.parametrize(
    "db_error",
    [
        SQLAlchemyError("db unreachable"),
        # Connection-level failures (e.g. the DB host is down) surface as raw
        # driver/OS errors, not wrapped in SQLAlchemyError — caught this via
        # manual testing against an unreachable Postgres host.
        ConnectionRefusedError("connection refused"),
    ],
    ids=["sqlalchemy_error", "connection_refused"],
)
async def test_health_db_unreachable_returns_503(client: AsyncClient, db_error: Exception) -> None:
    broken_session = AsyncMock(spec=AsyncSession)
    broken_session.execute.side_effect = db_error

    async def override_broken_session() -> AsyncIterator[AsyncSession]:
        yield broken_session

    app.dependency_overrides[get_session] = override_broken_session
    try:
        response = await client.get("/api/health")
    finally:
        app.dependency_overrides.pop(get_session, None)

    assert response.status_code == 503
    assert response.json() == {"status": "error", "database": "error"}
