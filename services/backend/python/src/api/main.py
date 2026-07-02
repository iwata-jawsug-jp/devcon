"""FastAPI application factory and ASGI entry point."""

from fastapi import FastAPI

from api import __version__
from api.config import get_settings
from api.routers import health, items


def create_app() -> FastAPI:
    """Build and configure the FastAPI application."""
    settings = get_settings()
    app = FastAPI(title=settings.app_name, version=__version__)
    app.include_router(health.router)
    app.include_router(items.router)
    return app


app = create_app()
