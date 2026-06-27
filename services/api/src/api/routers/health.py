"""Health-check endpoints."""

from typing import Annotated

from fastapi import APIRouter, Depends

from api.config import Settings, get_settings
from api.schemas.health import HealthStatus

router = APIRouter(prefix="/api", tags=["health"])


@router.get("/health", response_model=HealthStatus)
async def health(
    settings: Annotated[Settings, Depends(get_settings)],
) -> HealthStatus:
    """Return service health status."""
    _ = settings
    return HealthStatus(status="ok")
