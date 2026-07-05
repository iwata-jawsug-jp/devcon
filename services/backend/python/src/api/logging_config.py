"""Structured (JSON) logging with request-correlation IDs (issue #42)."""

from __future__ import annotations

import json
import logging
from contextvars import ContextVar
from datetime import UTC, datetime

from opentelemetry import trace

request_id_ctx: ContextVar[str | None] = ContextVar("request_id", default=None)

_RESERVED_RECORD_ATTRS = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "message",
    "asctime",
}


class JsonFormatter(logging.Formatter):
    """Render each log record as a single JSON line.

    Includes the current request's correlation ID (if any) so log lines from
    a single request — across routers, repositories, etc. — can be grepped
    together via ``request_id``, without threading it through every call.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        request_id = request_id_ctx.get()
        if request_id is not None:
            payload["request_id"] = request_id

        # Independent of request_id: lets a log line be opened directly in the
        # trace backend (ADR-0007). No-op (span_context.is_valid is False) when
        # tracing is disabled or there's no active span.
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            payload["trace_id"] = f"{span_context.trace_id:032x}"
            payload["span_id"] = f"{span_context.span_id:016x}"

        for key, value in record.__dict__.items():
            if key not in _RESERVED_RECORD_ATTRS:
                payload[key] = value

        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str)


def configure_logging(level: int | str = logging.INFO) -> None:
    """Replace the root logger's handlers with a single JSON-formatted stream handler."""
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
