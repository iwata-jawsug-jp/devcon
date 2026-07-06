"""Structured JSON response for otherwise-unhandled exceptions (#304).

Without this, an unhandled exception (e.g. a DB connection drop) falls through
to Starlette's default handler, which returns a bare, unstructured 500 body.
"""

from __future__ import annotations

import logging

from fastapi import Request, status
from fastapi.responses import JSONResponse

from api.middleware import REQUEST_ID_HEADER

logger = logging.getLogger("api.error")


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Log the exception and return a structured 500 response with the request's correlation ID.

    FastAPI routes bare-``Exception`` handlers to Starlette's
    ``ServerErrorMiddleware``, which sits *outside* ``CorrelationIdMiddleware`` --
    so `api.logging_config.request_id_ctx` has already been reset by the time
    this runs. Read the ID from ``request.state`` instead (set by that
    middleware on the ASGI scope, which this handler's ``Request`` shares).
    """
    request_id = getattr(request.state, "request_id", None)
    logger.exception(
        "unhandled exception",
        extra={
            "http_method": request.method,
            "http_path": request.url.path,
            "request_id": request_id,
        },
    )
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "Internal server error", "request_id": request_id},
        headers={REQUEST_ID_HEADER: request_id} if request_id else None,
    )
