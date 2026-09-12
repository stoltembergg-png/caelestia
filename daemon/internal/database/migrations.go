package database

import (
	"database/sql"
	"fmt"
)

// schemaVersionTable tracks the applied cae_* migrations.
const schemaVersionTable = "cae_schema_version"

// createSchemaVersionTable is run before anything else so the current version
// can be read. It intentionally does not depend on the migrations below.
const createSchemaVersionTable = `
CREATE TABLE IF NOT EXISTS ` + schemaVersionTable + ` (
	version INTEGER PRIMARY KEY
)`

// migration is a single, ordered, versioned set of DDL statements.
type migration struct {
	version    int
	name       string
	statements []string
}

// migrations lists every cae_* migration in ascending version order.
// Statements must be idempotent (IF NOT EXISTS) so re-running is safe.
var migrations = []migration{
	{
		version: 1,
		name:    "initial schema",
		statements: []string{
			// Accounts: one row per paired device.
			`CREATE TABLE IF NOT EXISTS cae_accounts (
				device_jid      TEXT PRIMARY KEY,
				push_name       TEXT NOT NULL DEFAULT '',
				platform        TEXT NOT NULL DEFAULT '',
				created_at      INTEGER NOT NULL DEFAULT (unixepoch()),
				last_connect_at INTEGER
			)`,

			// Chats (direct messages and groups).
			`CREATE TABLE IF NOT EXISTS cae_chats (
				jid              TEXT PRIMARY KEY,
				kind             TEXT NOT NULL DEFAULT 'dm'
					CHECK (kind IN ('dm', 'group')),
				name             TEXT NOT NULL DEFAULT '',
				last_message_id  TEXT,
				last_message_ts  INTEGER,
				last_preview     TEXT,
				unread_count     INTEGER NOT NULL DEFAULT 0,
				pinned           INTEGER NOT NULL DEFAULT 0,
				archived         INTEGER NOT NULL DEFAULT 0,
				mute_until       INTEGER,
				updated_at       INTEGER NOT NULL DEFAULT (unixepoch())
			)`,

			// Contacts.
			`CREATE TABLE IF NOT EXISTS cae_contacts (
				jid           TEXT PRIMARY KEY,
				first_name    TEXT,
				full_name     TEXT,
				push_name     TEXT,
				business_name TEXT,
				avatar_id     TEXT,
				avatar_path   TEXT,
				updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
			)`,

			// Groups.
			`CREATE TABLE IF NOT EXISTS cae_groups (
				jid               TEXT PRIMARY KEY,
				name              TEXT NOT NULL DEFAULT '',
				topic             TEXT,
				participants_json TEXT,
				updated_at        INTEGER NOT NULL DEFAULT (unixepoch())
			)`,

			// Messages. id is the whatsmeow MessageID; timestamps are epoch
			// seconds. media_id is resolved through cae_media.
			`CREATE TABLE IF NOT EXISTS cae_messages (
				id          TEXT PRIMARY KEY,
				chat_jid    TEXT NOT NULL
					REFERENCES cae_chats (jid) ON DELETE CASCADE,
				sender_jid  TEXT,
				from_me     INTEGER NOT NULL DEFAULT 0,
				timestamp   INTEGER NOT NULL DEFAULT 0,
				type        TEXT NOT NULL DEFAULT '',
				text        TEXT,
				quoted_id   TEXT,
				reaction_to TEXT,
				edited      INTEGER NOT NULL DEFAULT 0,
				deleted     INTEGER NOT NULL DEFAULT 0,
				server_id   INTEGER,
				status      TEXT,
				media_id    TEXT
			)`,

			// Per-user receipts; one row per (message, user, receipt type).
			`CREATE TABLE IF NOT EXISTS cae_receipts (
				message_id TEXT NOT NULL
					REFERENCES cae_messages (id) ON DELETE CASCADE,
				user_jid   TEXT NOT NULL,
				type       TEXT NOT NULL,
				ts         INTEGER NOT NULL,
				PRIMARY KEY (message_id, user_jid, type)
			)`,

			// Media metadata; the bytes always live on disk, never in the DB.
			`CREATE TABLE IF NOT EXISTS cae_media (
				id            TEXT PRIMARY KEY,
				message_id    TEXT
					REFERENCES cae_messages (id) ON DELETE SET NULL,
				kind          TEXT,
				mime          TEXT,
				size          INTEGER,
				path          TEXT,
				sha256        TEXT,
				status        TEXT,
				downloaded_at INTEGER
			)`,

			// Key/value sync bookkeeping (history_done, contacts_ts, ...).
			`CREATE TABLE IF NOT EXISTS cae_sync_state (
				key   TEXT PRIMARY KEY,
				value TEXT
			)`,

			// Indexes.
			`CREATE INDEX IF NOT EXISTS idx_cae_messages_chat_ts
				ON cae_messages (chat_jid, timestamp DESC)`,
			`CREATE INDEX IF NOT EXISTS idx_cae_messages_chat_server
				ON cae_messages (chat_jid, server_id)`,
			`CREATE INDEX IF NOT EXISTS idx_cae_chats_last_message_ts
				ON cae_chats (last_message_ts DESC)`,
			`CREATE INDEX IF NOT EXISTS idx_cae_chats_unread
				ON cae_chats (unread_count) WHERE unread_count > 0`,
		},
	},
}

// Migrate applies every pending migration exactly once. It is safe to call
// repeatedly: already-applied versions are skipped.
func Migrate(db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("database: migrate: nil db")
	}

	if _, err := db.Exec(createSchemaVersionTable); err != nil {
		return fmt.Errorf("database: create %s: %w", schemaVersionTable, err)
	}

	current, err := currentVersion(db)
	if err != nil {
		return err
	}

	for _, m := range migrations {
		if m.version <= current {
			continue
		}
		if err := applyMigration(db, m); err != nil {
			return fmt.Errorf("database: migration %d (%s): %w", m.version, m.name, err)
		}
	}
	return nil
}

func currentVersion(db *sql.DB) (int, error) {
	var version int
	if err := db.QueryRow(
		"SELECT COALESCE(MAX(version), 0) FROM " + schemaVersionTable,
	).Scan(&version); err != nil {
		return 0, fmt.Errorf("database: read schema version: %w", err)
	}
	return version, nil
}

func applyMigration(db *sql.DB, m migration) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() {
		// Rollback is a no-op after a successful Commit.
		_ = tx.Rollback()
	}()

	for i, stmt := range m.statements {
		if _, err := tx.Exec(stmt); err != nil {
			return fmt.Errorf("statement %d: %w", i+1, err)
		}
	}

	if _, err := tx.Exec(
		"INSERT INTO "+schemaVersionTable+" (version) VALUES (?)", m.version,
	); err != nil {
		return fmt.Errorf("record version: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
