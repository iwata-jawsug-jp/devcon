// Command worker is services/backend/go's first async, event-driven Lambda
// (#639, ADR-0024's role split: Go = async/event-driven). Deployed behind an
// SQS trigger; the AWS-side wiring is Phase 3 (#640) — this binary only needs
// to run correctly as a plain aws-lambda-go handler.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"

	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/config"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/db"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/db/sqlcgen"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/observability"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/worker"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	ctx := context.Background()

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	logger := observability.NewLogger()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("connect to database: %w", err)
	}
	defer pool.Close()

	tracing, err := observability.ConfigureTracing(ctx, cfg)
	if err != nil {
		return fmt.Errorf("configure tracing: %w", err)
	}

	handler := &worker.Handler{
		Queries: sqlcgen.New(pool),
		Tracer:  tracing.Tracer,
		Logger:  logger,
	}

	// Lambda may freeze the execution environment between invocations, so
	// spans must be flushed at the end of every invocation rather than relying
	// on the batch processor's background export (see Tracing.Flush's doc).
	lambda.Start(func(ctx context.Context, event events.SQSEvent) (events.SQSEventResponse, error) {
		response, handleErr := handler.Handle(ctx, event)
		if flushErr := tracing.Flush(ctx); flushErr != nil {
			logger.Error("failed to flush trace spans", "error", flushErr)
		}
		return response, handleErr
	})
	return nil
}
