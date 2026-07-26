package db

import _ "embed"

// SchemaSQL is the Alembic-migrated schema snapshot (see schema.sql's own
// header comment / services/backend/go/CLAUDE.md). Tests apply it directly to
// a throwaway Postgres database — see internal/worker's test helpers — so Go's
// test suite never depends on services/backend/python's Alembic toolchain.
//
//go:embed schema.sql
var SchemaSQL string
