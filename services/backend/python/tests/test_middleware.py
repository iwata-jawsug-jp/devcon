"""Tests for CorrelationIdMiddleware (issue #42)."""

from __future__ import annotations

import logging

import pytest
from httpx import AsyncClient

from api.middleware import REQUEST_ID_HEADER


class TestCorrelationIdMiddleware:
    async def test_generates_request_id_when_absent(self, client: AsyncClient) -> None:
        response = await client.get("/api/health")

        assert response.status_code == 200
        assert response.headers[REQUEST_ID_HEADER]

    async def test_echoes_client_supplied_request_id(self, client: AsyncClient) -> None:
        response = await client.get("/api/health", headers={REQUEST_ID_HEADER: "given-id"})

        assert response.headers[REQUEST_ID_HEADER] == "given-id"

    async def test_two_requests_get_different_ids(self, client: AsyncClient) -> None:
        first = await client.get("/api/health")
        second = await client.get("/api/health")

        assert first.headers[REQUEST_ID_HEADER] != second.headers[REQUEST_ID_HEADER]

    async def test_logs_request_outcome(
        self, client: AsyncClient, caplog: pytest.LogCaptureFixture
    ) -> None:
        with caplog.at_level(logging.INFO, logger="api.access"):
            response = await client.get("/api/health")

        record = next(r for r in caplog.records if r.name == "api.access")
        assert record.http_method == "GET"  # type: ignore[attr-defined]
        assert record.http_path == "/api/health"  # type: ignore[attr-defined]
        assert record.http_status == response.status_code  # type: ignore[attr-defined]
        assert record.duration_ms >= 0  # type: ignore[attr-defined]
