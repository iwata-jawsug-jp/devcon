"""Distributed tracing setup (ADR-0007): FastAPI + SQLAlchemy instrumentation,
exported via OTLP to the ADOT collector sidecar (which forwards to AWS X-Ray).
"""

from __future__ import annotations

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import SpanProcessor, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

from api.config import Settings
from api.db.engine import engine


def configure_tracing(
    app: FastAPI,
    settings: Settings,
    span_processor: SpanProcessor | None = None,
) -> None:
    """Instrument ``app`` and the DB engine for tracing, unless disabled.

    ``span_processor`` is an injection seam for tests (e.g. a
    ``SimpleSpanProcessor`` over an in-memory exporter); production code
    leaves it unset and gets the real OTLP-over-gRPC exporter.
    """
    if not settings.otel_traces_enabled:
        return

    provider = TracerProvider(resource=Resource.create({SERVICE_NAME: settings.otel_service_name}))
    processor = span_processor or BatchSpanProcessor(
        OTLPSpanExporter(endpoint=settings.otel_exporter_endpoint, insecure=True)
    )
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app)
    SQLAlchemyInstrumentor().instrument(engine=engine.sync_engine)
