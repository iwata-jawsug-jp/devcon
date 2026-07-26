// Command api is the minimal Go backend scaffold (services/backend/go, Phase 1 —
// see docs/proposal/go-backend-adoption-proposal.md and ADR-0024). It exists to
// prove the toolchain end-to-end (build, lint, test, CI, Dockerfile); real
// handlers land in later phases (#639).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
)

// HealthOutput is the response body for GET /healthz.
type HealthOutput struct {
	Body struct {
		Status string `json:"status" example:"ok" doc:"Service health status"`
	}
}

// newAPI builds the router and registers operations. Split out from main so
// tests can exercise it without starting a real network listener. Returning
// the huma.API alongside the router lets callers (e.g. the "openapi" CLI
// subcommand below) read the generated spec directly, without an HTTP round
// trip — the same "no server needed" shape as the Python backend's
// `app.openapi()` (see `make gen-types`).
func newAPI() (http.Handler, huma.API) {
	router := chi.NewMux()

	// huma.DefaultConfig wires up /openapi.json, /openapi.yaml, and a /docs UI
	// alongside the operations registered below.
	api := humachi.New(router, huma.DefaultConfig("devcon API (Go)", "0.1.0"))

	huma.Register(api, huma.Operation{
		OperationID: "get-healthz",
		Method:      http.MethodGet,
		Path:        "/healthz",
		Summary:     "Health check",
		Tags:        []string{"system"},
	}, func(_ context.Context, _ *struct{}) (*HealthOutput, error) {
		resp := &HealthOutput{}
		resp.Body.Status = "ok"
		return resp, nil
	})

	return router, api
}

// runOpenAPI prints this service's OpenAPI document as JSON to stdout and
// exits — no listener started. `make gen-types` invokes this (`go run
// ./cmd/api openapi`) to feed openapi-typescript, mirroring how the Python
// backend dumps `app.openapi()` without running uvicorn.
func runOpenAPI() error {
	_, api := newAPI()
	return json.NewEncoder(os.Stdout).Encode(api.OpenAPI())
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "openapi" {
		if err := runOpenAPI(); err != nil {
			slog.Error("failed to render openapi document", "error", err)
			os.Exit(1)
		}
		return
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	addr := ":8000"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}

	handler, _ := newAPI()
	srv := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		slog.Info("starting server", "addr", addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "error", err)
		os.Exit(1)
	}
}
