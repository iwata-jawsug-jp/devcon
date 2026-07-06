"""Request correlation ID + access logging middleware (issue #42)."""

from __future__ import annotations

import logging
import time
import uuid
from collections.abc import Awaitable, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

from api.logging_config import request_id_ctx

logger = logging.getLogger("api.access")

REQUEST_ID_HEADER = "X-Request-ID"


class CorrelationIdMiddleware(BaseHTTPMiddleware):
    """Assign each request a correlation ID and log its outcome.

    The ID comes from the client's ``X-Request-ID`` header if present,
    otherwise a new one is generated. It's published via
    :data:`api.logging_config.request_id_ctx` for the duration of the
    request — so any log call anywhere in the call stack (routers,
    repositories, ...) picks it up automatically — and echoed back in the
    response header so a caller (e.g. the frontend) can correlate its own
    request with the resulting server-side logs.
    """

    async def dispatch(
        self, request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        request_id = request.headers.get(REQUEST_ID_HEADER) or str(uuid.uuid4())
        token = request_id_ctx.set(request_id)
        # Also stash it on request.state (backed by the ASGI scope dict, not this
        # contextvar) so api.exception_handlers can still read it for exceptions
        # that reach ServerErrorMiddleware -- which sits *outside* this
        # middleware, after the `finally` below has already reset the contextvar.
        request.state.request_id = request_id
        start = time.perf_counter()
        try:
            response = await call_next(request)
            duration_ms = (time.perf_counter() - start) * 1000
            logger.info(
                "request handled",
                extra={
                    "http_method": request.method,
                    "http_path": request.url.path,
                    "http_status": response.status_code,
                    "duration_ms": round(duration_ms, 2),
                },
            )
            response.headers[REQUEST_ID_HEADER] = request_id
            return response
        finally:
            request_id_ctx.reset(token)
