// Package observability provides structured logging and distributed tracing
// shared by services/backend/go's entry points (mirrors
// services/backend/python's logging_config.py / tracing.py, issue #42 / ADR-0007).
package observability

import (
	"context"
	"log/slog"
	"os"

	"go.opentelemetry.io/otel/trace"
)

type correlationIDKey struct{}

// NewLogger returns a JSON-formatted slog.Logger writing to stdout — same
// "structured logs, not print" rule as Python's logging_config.py.
func NewLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stdout, nil))
}

// WithCorrelationID attaches id (e.g. an SQS message ID) to ctx so
// LoggerFromContext can enrich every log line for this invocation with it —
// the Go-idiomatic equivalent of Python's request_id contextvar
// (logging_config.py), passed explicitly via context.Context instead of
// package-level mutable state (services/backend/go/CLAUDE.md).
func WithCorrelationID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, correlationIDKey{}, id)
}

// CorrelationID returns the ID attached by WithCorrelationID, if any.
func CorrelationID(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(correlationIDKey{}).(string)
	return id, ok
}

// LoggerFromContext returns base enriched with ctx's correlation ID and, if a
// valid span is active, its trace/span IDs — mirrors Python's JsonFormatter
// attaching request_id/trace_id/span_id so log lines can be correlated with a
// specific invocation and, when tracing is enabled, jumped to in the trace
// backend (ADR-0007).
func LoggerFromContext(ctx context.Context, base *slog.Logger) *slog.Logger {
	logger := base
	if id, ok := CorrelationID(ctx); ok {
		logger = logger.With("correlation_id", id)
	}
	spanContext := trace.SpanContextFromContext(ctx)
	if spanContext.IsValid() {
		logger = logger.With(
			"trace_id", spanContext.TraceID().String(),
			"span_id", spanContext.SpanID().String(),
		)
	}
	return logger
}
