// Package worker implements services/backend/go's first asynchronous,
// event-driven use case (#639, proposal §5's role split: Python owns
// synchronous REST, Go owns async/event-driven). The trigger itself
// (SQS/EventBridge wiring in AWS) is Phase 3 (#640); this package only proves
// the application-level vertical slice — sqlc/pgx DB access, structured
// logging + correlation ID, and tracing — against aws-lambda-go's SQS event
// shape.
package worker

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"

	"github.com/aws/aws-lambda-go/events"
	"github.com/jackc/pgx/v5"
	"go.opentelemetry.io/otel/trace"

	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/db/sqlcgen"
	"github.com/iwata-jawsug-jp/devcon/services/backend/go/internal/observability"
)

// ItemNoteMessage is the expected JSON body of each SQS record: append Note
// to the item's description.
type ItemNoteMessage struct {
	ItemID int32  `json:"item_id"`
	Note   string `json:"note"`
}

// Handler processes ItemNoteMessage records read from an SQS event.
type Handler struct {
	Queries *sqlcgen.Queries
	Tracer  trace.Tracer
	Logger  *slog.Logger
}

// Handle implements aws-lambda-go's SQS batch handler shape. Failures are
// reported per-record via BatchItemFailures (not by returning a top-level
// error) so SQS retries/DLQs only the records that actually failed, not the
// whole batch — standard practice for SQS-triggered Lambdas.
func (h *Handler) Handle(ctx context.Context, event events.SQSEvent) (events.SQSEventResponse, error) {
	response := events.SQSEventResponse{}
	for _, record := range event.Records {
		if err := h.handleRecord(ctx, record); err != nil {
			response.BatchItemFailures = append(response.BatchItemFailures, events.SQSBatchItemFailure{
				ItemIdentifier: record.MessageId,
			})
		}
	}
	return response, nil
}

func (h *Handler) handleRecord(ctx context.Context, record events.SQSMessage) error {
	ctx = observability.WithCorrelationID(ctx, record.MessageId)
	ctx, span := h.Tracer.Start(ctx, "process-item-note")
	defer span.End()

	logger := observability.LoggerFromContext(ctx, h.Logger)

	var msg ItemNoteMessage
	if err := json.Unmarshal([]byte(record.Body), &msg); err != nil {
		logger.Error("invalid message body", "error", err)
		return err
	}

	item, err := h.Queries.GetItem(ctx, msg.ItemID)
	if errors.Is(err, pgx.ErrNoRows) {
		logger.Warn("item not found", "item_id", msg.ItemID)
		return err
	}
	if err != nil {
		logger.Error("failed to fetch item", "item_id", msg.ItemID, "error", err)
		return err
	}

	updated, err := h.Queries.AppendItemNote(ctx, sqlcgen.AppendItemNoteParams{
		ID:   msg.ItemID,
		Note: msg.Note,
	})
	if err != nil {
		logger.Error("failed to append note", "item_id", msg.ItemID, "error", err)
		return err
	}

	logger.Info("appended note to item",
		"item_id", updated.ID,
		"item_name", item.Name,
		"note", msg.Note,
	)
	return nil
}
