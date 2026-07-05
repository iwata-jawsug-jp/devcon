"""Unit tests for the JSON log formatter and its request-ID correlation."""

from __future__ import annotations

import json
import logging

from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from api.logging_config import JsonFormatter, request_id_ctx


def _make_record(**extra: object) -> logging.LogRecord:
    record = logging.LogRecord(
        name="api.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="hello %s",
        args=("world",),
        exc_info=None,
    )
    for key, value in extra.items():
        setattr(record, key, value)
    return record


class TestJsonFormatter:
    def test_basic_fields(self) -> None:
        record = _make_record()
        payload = json.loads(JsonFormatter().format(record))

        assert payload["level"] == "INFO"
        assert payload["logger"] == "api.test"
        assert payload["message"] == "hello world"
        assert "timestamp" in payload
        assert "request_id" not in payload

    def test_includes_trace_id_from_active_span(self) -> None:
        provider = TracerProvider()
        exporter = InMemorySpanExporter()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        tracer = provider.get_tracer(__name__)

        with tracer.start_as_current_span("test-span"):
            payload = json.loads(JsonFormatter().format(_make_record()))

        assert len(payload["trace_id"]) == 32
        assert len(payload["span_id"]) == 16

    def test_no_trace_id_without_active_span(self) -> None:
        payload = json.loads(JsonFormatter().format(_make_record()))

        assert "trace_id" not in payload
        assert "span_id" not in payload

    def test_includes_request_id_from_contextvar(self) -> None:
        token = request_id_ctx.set("abc-123")
        try:
            payload = json.loads(JsonFormatter().format(_make_record()))
        finally:
            request_id_ctx.reset(token)

        assert payload["request_id"] == "abc-123"

    def test_includes_extra_fields(self) -> None:
        record = _make_record(http_method="GET", http_status=200, duration_ms=12.3)
        payload = json.loads(JsonFormatter().format(record))

        assert payload["http_method"] == "GET"
        assert payload["http_status"] == 200
        assert payload["duration_ms"] == 12.3

    def test_includes_exception_info(self) -> None:
        try:
            raise ValueError("boom")
        except ValueError:
            import sys

            record = logging.LogRecord(
                name="api.test",
                level=logging.ERROR,
                pathname=__file__,
                lineno=1,
                msg="failed",
                args=(),
                exc_info=sys.exc_info(),
            )

        payload = json.loads(JsonFormatter().format(record))
        assert "ValueError: boom" in payload["exc_info"]
