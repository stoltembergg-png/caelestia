package database

import (
	"database/sql"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// expectedTables are the cae_* tables required by ARQUITETURA.md §4.
var expectedTables = []string{
	"cae_schema_version",
	"cae_accounts",
	"cae_chats",
	"cae_contacts",
	"cae_groups",
	"cae_messages",
	"cae_receipts",
	"cae_media",
	"cae_sync_state",
}

// expectedIndexes are the named indexes required by ARQUITETURA.md §4.
var expectedIndexes = []string{
	"idx_cae_messages_chat_ts",
	"idx_cae_messages_chat_server",
	"idx_cae_chats_last_message_ts",
	"idx_cae_chats_unread",
}

func openTestDB(t *testing.T) (*sql.DB, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "whatsapp.db")

	db, err := Open(path)
	if err != nil {
		t.Fatalf("Open(%q) returned error: %v", path, err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("Close() returned error: %v", err)
		}
	})
	return db, path
}

func TestMigrateIsIdempotent(t *testing.T) {
	db, path := openTestDB(t)

	// Running the migration again on an already-migrated database must be a
	// no-op and must not fail.
	if err := Migrate(db); err != nil {
		t.Fatalf("second Migrate() returned error: %v", err)
	}
	if err := Migrate(db); err != nil {
		t.Fatalf("third Migrate() returned error: %v", err)
	}

	var count int
	if err := db.QueryRow(
		"SELECT COUNT(*) FROM " + schemaVersionTable,
	).Scan(&count); err != nil {
		t.Fatalf("count schema versions: %v", err)
	}
	if count != len(migrations) {
		t.Fatalf("schema version rows = %d, want %d", count, len(migrations))
	}

	// Reopening the same file must not duplicate anything.
	if err := db.Close(); err != nil {
		t.Fatalf("Close() before reopen: %v", err)
	}
	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen Open() returned error: %v", err)
	}
	defer reopened.Close()

	var rows int
	if err := reopened.QueryRow(
		"SELECT COUNT(*) FROM " + schemaVersionTable,
	).Scan(&rows); err != nil {
		t.Fatalf("count schema versions after reopen: %v", err)
	}
	if rows != len(migrations) {
		t.Fatalf("schema version rows after reopen = %d, want %d", rows, len(migrations))
	}
}

func TestSchemaObjectsExist(t *testing.T) {
	db, _ := openTestDB(t)

	for _, name := range expectedTables {
		var found string
		err := db.QueryRow(
			`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, name,
		).Scan(&found)
		if err == sql.ErrNoRows {
			t.Errorf("missing table %q", name)
			continue
		}
		if err != nil {
			t.Fatalf("query table %q: %v", name, err)
		}
	}

	for _, name := range expectedIndexes {
		var found string
		err := db.QueryRow(
			`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, name,
		).Scan(&found)
		if err == sql.ErrNoRows {
			t.Errorf("missing index %q", name)
			continue
		}
		if err != nil {
			t.Fatalf("query index %q: %v", name, err)
		}
	}
}

func TestPragmas(t *testing.T) {
	db, _ := openTestDB(t)

	var foreignKeys int
	if err := db.QueryRow("PRAGMA foreign_keys").Scan(&foreignKeys); err != nil {
		t.Fatalf("PRAGMA foreign_keys: %v", err)
	}
	if foreignKeys != 1 {
		t.Errorf("foreign_keys = %d, want 1", foreignKeys)
	}

	var journalMode string
	if err := db.QueryRow("PRAGMA journal_mode").Scan(&journalMode); err != nil {
		t.Fatalf("PRAGMA journal_mode: %v", err)
	}
	if journalMode != "wal" {
		t.Errorf("journal_mode = %q, want \"wal\"", journalMode)
	}

	var busyTimeout int
	if err := db.QueryRow("PRAGMA busy_timeout").Scan(&busyTimeout); err != nil {
		t.Fatalf("PRAGMA busy_timeout: %v", err)
	}
	if busyTimeout != 10000 {
		t.Errorf("busy_timeout = %d, want 10000", busyTimeout)
	}
}

func TestForeignKeyViolationFails(t *testing.T) {
	db, _ := openTestDB(t)

	_, err := db.Exec(
		`INSERT INTO cae_messages (id, chat_jid, timestamp)
		 VALUES ('m1', 'does-not-exist@s.whatsapp.net', 1)`,
	)
	if err == nil {
		t.Fatal("insert with dangling chat_jid succeeded, want foreign key violation")
	}
}

func TestFilePermissionIs0600(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("file permission check is Linux-specific")
	}

	_, path := openTestDB(t)

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat(%q): %v", path, err)
	}
	if got := info.Mode().Perm(); got != FilePerm {
		t.Errorf("database file mode = %04o, want %04o", got, FilePerm)
	}
}
