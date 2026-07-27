"""Tests for get_session's commit/rollback wiring (unit-of-work boundary).

The app-level test fixtures (tests/conftest.py) override ``get_session`` entirely with a
version that never commits, so those integration tests never exercise this file's actual
commit/rollback logic. Isolate it here with a fake session so no real engine is needed.
"""

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from typing import cast
from unittest.mock import AsyncMock

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from api.db import session as session_module


def _install_fake_session_local(monkeypatch: pytest.MonkeyPatch, fake_session: AsyncMock) -> None:
    @asynccontextmanager
    async def fake_session_local() -> AsyncGenerator[AsyncMock]:
        yield fake_session

    monkeypatch.setattr(session_module, "AsyncSessionLocal", fake_session_local)


def _get_session_generator() -> AsyncGenerator[AsyncSession]:
    # get_session() is annotated AsyncIterator[AsyncSession] (the FastAPI-idiomatic
    # dependency return type), but it's a generator function -- cast so tests can drive
    # it directly with __anext__/athrow like the ASGI framework does.
    return cast(AsyncGenerator[AsyncSession], session_module.get_session())


async def test_get_session_commits_when_the_request_succeeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_session = AsyncMock(spec=AsyncSession)
    _install_fake_session_local(monkeypatch, fake_session)

    agen = _get_session_generator()
    yielded = await agen.__anext__()
    assert yielded is fake_session

    with pytest.raises(StopAsyncIteration):
        await agen.__anext__()

    fake_session.commit.assert_awaited_once()
    fake_session.rollback.assert_not_called()


async def test_get_session_rolls_back_when_the_request_raises(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_session = AsyncMock(spec=AsyncSession)
    _install_fake_session_local(monkeypatch, fake_session)

    agen = _get_session_generator()
    await agen.__anext__()

    with pytest.raises(RuntimeError, match="boom"):
        await agen.athrow(RuntimeError("boom"))

    fake_session.rollback.assert_awaited_once()
    fake_session.commit.assert_not_called()
