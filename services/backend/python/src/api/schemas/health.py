"""Health-check schemas."""

from pydantic import BaseModel


class HealthStatus(BaseModel):
    """Service health status."""

    status: str
    database: str
