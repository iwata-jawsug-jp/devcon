"""Tests for the unhandled-exception handler (#304)."""

from __future__ import annotations

from collections.abc import Callable

import pytest
from httpx import ASGITransport, AsyncClient

from api.main import app
from api.middleware import REQUEST_ID_HEADER
from api.repositories.items import ItemRepository

AuthedClientFactory = Callable[[list[str] | None], AsyncClient]


class TestUnhandledExceptionHandler:
    async def test_returns_structured_500_with_request_id(
        self,
        authed_client: AuthedClientFactory,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        async def broken_list(self: ItemRepository) -> None:
            raise RuntimeError("simulated DB connection drop")

        monkeypatch.setattr(ItemRepository, "list_", broken_list)

        # authed_client() installs the auth/session dependency overrides on the
        # shared `app`; use our own transport with raise_app_exceptions=False so
        # we can assert on the response Starlette's ServerErrorMiddleware sends,
        # instead of the exception it re-raises afterwards for server-side logging.
        authed_client(None)
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.get("/api/items", headers={REQUEST_ID_HEADER: "test-req-id"})

        assert response.status_code == 500
        body = response.json()
        assert body["detail"] == "Internal server error"
        assert body["request_id"] == "test-req-id"
        assert response.headers[REQUEST_ID_HEADER] == "test-req-id"
