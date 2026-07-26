package worker_test

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"os"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.opentelemetry.io/otel"

	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/db"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/db/sqlcgen"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/worker"
)

// testDBName is a throwaway database, isolated from the `app` database
// services/backend/python's Alembic owns — the Go test suite never depends on
// Alembic having run (#639, proposal §2.3.1's "apply schema.sql directly").
const testDBName = "backend_go_test"

// newTestPool creates (or recreates) testDBName on the same Postgres server
// as TEST_DATABASE_URL (docker-compose locally, a postgres service in CI) and
// applies internal/db/schema.sql to it directly.
func newTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()

	adminURL := os.Getenv("TEST_DATABASE_URL")
	if adminURL == "" {
		// Local docker-compose / CI's postgres service default (docker-compose.yml's own
		// committed POSTGRES_PASSWORD) — not a secret.
		adminURL = "postgres://app:app@localhost:5432/postgres" //nolint:gosec // dev-only default credential, matches docker-compose.yml
	}

	adminPool, err := pgxpool.New(ctx, adminURL)
	if err != nil {
		t.Fatalf("connect to admin database: %v", err)
	}
	defer adminPool.Close()

	if _, err := adminPool.Exec(ctx, "DROP DATABASE IF EXISTS "+testDBName+" WITH (FORCE)"); err != nil {
		t.Fatalf("drop test database: %v", err)
	}
	if _, err := adminPool.Exec(ctx, "CREATE DATABASE "+testDBName); err != nil {
		t.Fatalf("create test database: %v", err)
	}

	testURL := withDBName(t, adminURL, testDBName)

	// Apply schema.sql on a single, one-off connection that is discarded
	// immediately after, never returned to the pool below. pg_dump's output
	// sets search_path to '' (so its own DDL is unambiguous regardless of the
	// restoring session's search_path) and that SET persists for the
	// connection's lifetime — if this connection were reused from a pool,
	// every later unqualified table reference on it would fail to resolve.
	setupConn, err := pgx.Connect(ctx, testURL)
	if err != nil {
		t.Fatalf("connect for schema setup: %v", err)
	}
	_, execErr := setupConn.Exec(ctx, db.SchemaSQL)
	if closeErr := setupConn.Close(ctx); closeErr != nil {
		t.Logf("close schema setup connection: %v", closeErr)
	}
	if execErr != nil {
		t.Fatalf("apply schema.sql: %v", execErr)
	}

	pool, err := pgxpool.New(ctx, testURL)
	if err != nil {
		t.Fatalf("connect to test database: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func withDBName(t *testing.T, rawURL, dbName string) string {
	t.Helper()
	u, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse database url: %v", err)
	}
	u.Path = "/" + dbName
	return u.String()
}

func newHandler(t *testing.T, pool *pgxpool.Pool) *worker.Handler {
	t.Helper()
	return &worker.Handler{
		Queries: sqlcgen.New(pool),
		Tracer:  otel.Tracer("test"),
		Logger:  slog.New(slog.NewJSONHandler(os.Stderr, nil)),
	}
}

func sqsRecord(t *testing.T, messageID string, msg worker.ItemNoteMessage) events.SQSMessage {
	t.Helper()
	body, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	return events.SQSMessage{MessageId: messageID, Body: string(body)}
}

func TestHandle_AppendsNoteToExistingItem(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()

	var itemID int32
	err := pool.QueryRow(ctx,
		"INSERT INTO items (name, description) VALUES ($1, $2) RETURNING id",
		"widget", "original description",
	).Scan(&itemID)
	if err != nil {
		t.Fatalf("seed item: %v", err)
	}

	h := newHandler(t, pool)
	event := events.SQSEvent{Records: []events.SQSMessage{
		sqsRecord(t, "msg-1", worker.ItemNoteMessage{ItemID: itemID, Note: "processed by worker"}),
	}}

	response, err := h.Handle(ctx, event)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}
	if len(response.BatchItemFailures) != 0 {
		t.Fatalf("expected no batch item failures, got %+v", response.BatchItemFailures)
	}

	var description string
	if err := pool.QueryRow(ctx, "SELECT description FROM items WHERE id = $1", itemID).Scan(&description); err != nil {
		t.Fatalf("read back item: %v", err)
	}
	const want = "original description | processed by worker"
	if description != want {
		t.Fatalf("description = %q, want %q", description, want)
	}
}

func TestHandle_AppendsNoteToItemWithNoDescription(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()

	var itemID int32
	err := pool.QueryRow(ctx,
		"INSERT INTO items (name, description) VALUES ($1, NULL) RETURNING id", "gadget",
	).Scan(&itemID)
	if err != nil {
		t.Fatalf("seed item: %v", err)
	}

	h := newHandler(t, pool)
	event := events.SQSEvent{Records: []events.SQSMessage{
		sqsRecord(t, "msg-2", worker.ItemNoteMessage{ItemID: itemID, Note: "first note"}),
	}}

	if _, err := h.Handle(ctx, event); err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}

	var description string
	if err := pool.QueryRow(ctx, "SELECT description FROM items WHERE id = $1", itemID).Scan(&description); err != nil {
		t.Fatalf("read back item: %v", err)
	}
	if description != "first note" {
		t.Fatalf("description = %q, want %q", description, "first note")
	}
}

func TestHandle_ReportsBatchItemFailureForMissingItem(t *testing.T) {
	pool := newTestPool(t)
	h := newHandler(t, pool)

	event := events.SQSEvent{Records: []events.SQSMessage{
		sqsRecord(t, "msg-missing", worker.ItemNoteMessage{ItemID: 999999, Note: "no such item"}),
	}}

	response, err := h.Handle(context.Background(), event)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}
	if len(response.BatchItemFailures) != 1 {
		t.Fatalf("expected 1 batch item failure, got %d", len(response.BatchItemFailures))
	}
	if response.BatchItemFailures[0].ItemIdentifier != "msg-missing" {
		t.Fatalf("failure ItemIdentifier = %q, want %q", response.BatchItemFailures[0].ItemIdentifier, "msg-missing")
	}
}

func TestHandle_ReportsBatchItemFailureForMalformedBody(t *testing.T) {
	pool := newTestPool(t)
	h := newHandler(t, pool)

	event := events.SQSEvent{Records: []events.SQSMessage{
		{MessageId: "msg-bad-json", Body: "not json"},
	}}

	response, err := h.Handle(context.Background(), event)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}
	if len(response.BatchItemFailures) != 1 {
		t.Fatalf("expected 1 batch item failure, got %d", len(response.BatchItemFailures))
	}
}

func TestHandle_ProcessesRemainingRecordsAfterOneFailure(t *testing.T) {
	pool := newTestPool(t)
	ctx := context.Background()

	var itemID int32
	err := pool.QueryRow(ctx,
		"INSERT INTO items (name, description) VALUES ($1, NULL) RETURNING id", "widget-2",
	).Scan(&itemID)
	if err != nil {
		t.Fatalf("seed item: %v", err)
	}

	h := newHandler(t, pool)
	event := events.SQSEvent{Records: []events.SQSMessage{
		sqsRecord(t, "msg-missing", worker.ItemNoteMessage{ItemID: 999999, Note: "no such item"}),
		sqsRecord(t, "msg-ok", worker.ItemNoteMessage{ItemID: itemID, Note: "still processed"}),
	}}

	response, err := h.Handle(ctx, event)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}
	if len(response.BatchItemFailures) != 1 || response.BatchItemFailures[0].ItemIdentifier != "msg-missing" {
		t.Fatalf("expected exactly the missing-item failure, got %+v", response.BatchItemFailures)
	}

	var description string
	if err := pool.QueryRow(ctx, "SELECT description FROM items WHERE id = $1", itemID).Scan(&description); err != nil {
		t.Fatalf("read back item: %v", err)
	}
	if description != "still processed" {
		t.Fatalf("description = %q, want %q", description, "still processed")
	}
}
