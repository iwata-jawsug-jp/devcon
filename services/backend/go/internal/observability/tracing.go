package observability

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/config"
)

// Tracing bundles the tracer used to start spans and a flush hook the caller
// must invoke after each unit of work completes.
type Tracing struct {
	Tracer trace.Tracer
	// Flush exports any buffered spans immediately. Lambda may freeze the
	// execution environment between invocations, so — unlike a long-running
	// server that can rely on the batch processor's background export —
	// callers must invoke Flush at the end of every invocation or spans can be
	// lost. No-op when tracing is disabled.
	Flush func(context.Context) error
}

// ConfigureTracing sets up OTLP/gRPC tracing per ADR-0007 (SDK -> ADOT
// collector -> AWS X-Ray), unless cfg.OtelTracesEnabled is false (the
// default — mirrors services/backend/python/src/api/tracing.py). The ADOT
// endpoint itself (a Lambda extension in production) is wired up in Phase 3
// (#640); here the endpoint is just configuration.
func ConfigureTracing(ctx context.Context, cfg config.Settings) (Tracing, error) {
	if !cfg.OtelTracesEnabled {
		return Tracing{
			Tracer: otel.Tracer(cfg.OtelServiceName),
			Flush:  func(context.Context) error { return nil },
		}, nil
	}

	conn, err := grpc.NewClient(cfg.OtelExporterEndpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return Tracing{}, err
	}

	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
	if err != nil {
		return Tracing{}, err
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewSchemaless(attribute.String("service.name", cfg.OtelServiceName)),
	)
	if err != nil {
		return Tracing{}, err
	}

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(provider)

	return Tracing{
		Tracer: provider.Tracer(cfg.OtelServiceName),
		Flush:  provider.ForceFlush,
	}, nil
}
