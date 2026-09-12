package database

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestAcquireLockIsExclusive(t *testing.T) {
	path := filepath.Join(t.TempDir(), "daemon.lock")

	l1, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("first AcquireLock: %v", err)
	}

	// A second open file description on the same path must be refused, which
	// is exactly what stops a second daemon on the same data-dir.
	if _, err := AcquireLock(path); !errors.Is(err, ErrLocked) {
		t.Fatalf("second AcquireLock = %v, want ErrLocked", err)
	}

	if err := l1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// After releasing, the lock is available again.
	l2, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock after release: %v", err)
	}
	if err := l2.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

func TestAcquireLockFilePermissions(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("file permission check is Linux-specific")
	}
	path := filepath.Join(t.TempDir(), "daemon.lock")

	l, err := AcquireLock(path)
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	defer l.Close()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if got := info.Mode().Perm(); got != FilePerm {
		t.Errorf("lock file mode = %04o, want %04o", got, FilePerm)
	}
}

func TestAcquireLockEmptyPath(t *testing.T) {
	if _, err := AcquireLock(""); err == nil {
		t.Fatal("AcquireLock(\"\") succeeded, want error")
	}
}
