"""FastAPI application factory and ASGI entry point."""

from fastapi import FastAPI

from api import __version__
from api.config import get_settings
from api.logging_config import configure_logging
from api.middleware import CorrelationIdMiddleware
from api.routers import health, items
from api.tracing import configure_tracing


def create_app() -> FastAPI:
    """Build and configure the FastAPI application."""
    configure_logging()
    settings = get_settings()
    app = FastAPI(title=settings.app_name, version=__version__)
    configure_tracing(app, settings)
    app.add_middleware(CorrelationIdMiddleware)
    app.include_router(health.router)
    app.include_router(items.router)
    return app


app = create_app()
