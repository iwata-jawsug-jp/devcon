-- Queries against the `items` table (owned by services/backend/python's Alembic — see
-- internal/db/schema.sql). Backs the worker's item-note-append job (cmd/worker, #639).

-- name: GetItem :one
SELECT id, name, description FROM items WHERE id = $1;

-- name: AppendItemNote :one
UPDATE items
SET description = concat_ws(' | ', description, sqlc.arg(note)::text)
WHERE id = sqlc.arg(id)
RETURNING id, name, description;
