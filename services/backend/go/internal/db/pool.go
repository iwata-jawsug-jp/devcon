// Package db holds the pgx connection pool and the schema snapshot/queries
// sqlc reads (internal/db/schema.sql, internal/db/queries/*.sql) — see
// services/backend/go/CLAUDE.md and proposal §2.3.1. Generated code lives in
// the sqlcgen subpackage (never hand-edited).
package db

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// NewPool opens a pgx connection pool against databaseURL. Callers must
// Close() it (e.g. via defer) when done.
func NewPool(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	return pgxpool.New(ctx, databaseURL)
}
