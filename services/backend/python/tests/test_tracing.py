"""Tests for configure_tracing (ADR-0007)."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from fastapi import FastAPI

from api.config import Settings
from api.tracing import configure_tracing


class TestConfigureTracing:
    def test_disabled_by_default_does_nothing(self) -> None:
        app = FastAPI()
        settings = Settings(otel_traces_enabled=False)

        with (
            patch("api.tracing.FastAPIInstrumentor") as fastapi_instrumentor,
            patch("api.tracing.SQLAlchemyInstrumentor") as sqlalchemy_instrumentor,
            patch("api.tracing.trace") as trace_module,
        ):
            configure_tracing(app, settings)

        fastapi_instrumentor.instrument_app.assert_not_called()
        sqlalchemy_instrumentor.assert_not_called()
        trace_module.set_tracer_provider.assert_not_called()

    def test_enabled_instruments_app_and_engine(self) -> None:
        app = FastAPI()
        settings = Settings(otel_traces_enabled=True, otel_service_name="api-test")
        span_processor = MagicMock()

        with (
            patch("api.tracing.FastAPIInstrumentor") as fastapi_instrumentor,
            patch("api.tracing.SQLAlchemyInstrumentor") as sqlalchemy_instrumentor,
            patch("api.tracing.trace") as trace_module,
            patch("api.tracing.TracerProvider") as tracer_provider_cls,
        ):
            provider_instance = tracer_provider_cls.return_value
            configure_tracing(app, settings, span_processor=span_processor)

        fastapi_instrumentor.instrument_app.assert_called_once_with(app)
        sqlalchemy_instrumentor.return_value.instrument.assert_called_once()
        provider_instance.add_span_processor.assert_called_once_with(span_processor)
        trace_module.set_tracer_provider.assert_called_once_with(provider_instance)
