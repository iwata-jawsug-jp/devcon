"""Health-check endpoints."""

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from api.config import Settings, get_settings
from api.db.session import get_session
from api.schemas.health import HealthStatus

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["health"])


@router.get("/health", response_model=HealthStatus)
async def health(
    settings: Annotated[Settings, Depends(get_settings)],
    session: Annotated[AsyncSession, Depends(get_session)],
    response: Response,
) -> HealthStatus:
    """Return service health, including DB reachability.

    This is also the ALB target-group health check (``infra/api.tf``), so a DB
    outage now correctly takes the target out of rotation instead of reporting
    "ok" while every real request would fail (#42, #153 finding #10).
    """
    _ = settings
    try:
        await session.execute(text("SELECT 1"))
    except Exception:  # noqa: BLE001 - a health check must never 500; report degraded instead
        # Deliberately broad: connection-level failures (e.g. ConnectionRefusedError)
        # surface as raw driver/OS errors here, not just sqlalchemy.exc.SQLAlchemyError.
        logger.exception("health check: database unreachable")
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return HealthStatus(status="error", database="error")
    return HealthStatus(status="ok", database="ok")
