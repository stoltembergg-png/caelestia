// Package database owns the SQLite connection and the cae_* schema.
//
// The database file is created with 0600 permissions and configured with
// foreign keys, WAL journaling, a busy timeout and NORMAL synchronous mode.
// Writes are serialized by limiting the pool to a single connection.
package database

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	// modernc.org/sqlite is a pure-Go SQLite driver (no CGO).
	_ "modernc.org/sqlite"
)

const (
	// DriverName is the database/sql driver registered by modernc.org/sqlite.
	DriverName = "sqlite"

	// FilePerm is the permission of the database file (owner only).
	FilePerm = os.FileMode(0o600)

	// DirPerm is the permission of directories created for the database.
	DirPerm = os.FileMode(0o700)
)

// dsn builds the modernc.org/sqlite connection string with the required pragmas.
func dsn(path string) string {
	return "file:" + path + "?_pragma=foreign_keys(1)" +
		"&_pragma=journal_mode(WAL)" +
		"&_pragma=busy_timeout(10000)" +
		"&_pragma=synchronous(NORMAL)"
}

// Open opens (creating if needed) the SQLite database at path, applies the
// required pragmas and runs the cae_* migrations. The caller owns the returned
// *sql.DB and must call Close on it.
func Open(path string) (*sql.DB, error) {
	if path == "" {
		return nil, errors.New("database: empty path")
	}

	if dir := filepath.Dir(path); dir != "" && dir != "." {
		if err := os.MkdirAll(dir, DirPerm); err != nil {
			return nil, fmt.Errorf("database: create directory %q: %w", dir, err)
		}
	}

	// Pre-create the file with restrictive permissions so the mode does not
	// depend on the process umask. Existing files are handled by the chmod
	// below.
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, FilePerm)
	if err != nil {
		return nil, fmt.Errorf("database: create file %q: %w", path, err)
	}
	if err := f.Close(); err != nil {
		return nil, fmt.Errorf("database: close file %q: %w", path, err)
	}
	if err := os.Chmod(path, FilePerm); err != nil {
		return nil, fmt.Errorf("database: chmod %q: %w", path, err)
	}

	db, err := sql.Open(DriverName, dsn(path))
	if err != nil {
		return nil, fmt.Errorf("database: open %q: %w", path, err)
	}

	// Single writer: avoid "database is locked" and keep pragmas consistent.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("database: ping %q: %w", path, err)
	}

	if err := Migrate(db); err != nil {
		_ = db.Close()
		return nil, err
	}

	// SQLite creates the -wal/-shm sidecars on demand; keep them private too.
	chmodIfExists(path + "-wal")
	chmodIfExists(path + "-shm")

	return db, nil
}

// chmodIfExists restricts sidecar files to the owner. Missing files are ignored.
func chmodIfExists(path string) {
	if _, err := os.Stat(path); err == nil {
		_ = os.Chmod(path, FilePerm)
	}
}
