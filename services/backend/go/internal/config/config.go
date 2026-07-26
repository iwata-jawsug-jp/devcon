// Package config binds runtime settings from environment variables (mirrors
// services/backend/python's pydantic-settings `Settings`, proposal §2.4).
package config

import "github.com/caarlos0/env/v11"

// Settings holds the worker's runtime configuration. All fields come from
// environment variables — no config files, no secrets committed (root
// CLAUDE.md).
type Settings struct {
	// DatabaseURL is a pgx-compatible connection string
	// (postgres://user:pass@host:port/dbname). Defaults to the docker-compose
	// Postgres used by `make db-up` / CI's postgres service (mirrors Python's
	// API_DATABASE_URL default in services/backend/python/src/api/config.py).
	DatabaseURL string `env:"DATABASE_URL" envDefault:"postgres://app:app@localhost:5432/app"`

	// OtelTracesEnabled mirrors Python's API_OTEL_TRACES_ENABLED (ADR-0007) — off by
	// default (e.g. local dev / tests have no collector to send to).
	OtelTracesEnabled bool `env:"OTEL_TRACES_ENABLED" envDefault:"false"`
	// OtelExporterEndpoint is the OTLP/gRPC collector endpoint. In Lambda this
	// would be the ADOT Lambda extension's local endpoint (Phase 3, #640).
	OtelExporterEndpoint string `env:"OTEL_EXPORTER_ENDPOINT" envDefault:"localhost:4317"`
	OtelServiceName      string `env:"OTEL_SERVICE_NAME" envDefault:"backend-go-worker"`
}

// Load reads Settings from the environment (no `WORKER_`/`API_`-style prefix —
// Go has its own service boundary, same rule as services/backend/go/CLAUDE.md's
// existing PORT handling).
func Load() (Settings, error) {
	var s Settings
	if err := env.Parse(&s); err != nil {
		return Settings{}, err
	}
	return s, nil
}
