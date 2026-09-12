package database

import (
	"errors"
	"fmt"
	"os"
	"sync"

	"golang.org/x/sys/unix"
)

// ErrLocked is returned by AcquireLock when another process already holds the
// data-directory lock.
var ErrLocked = errors.New("database: data directory is locked by another process")

// FileLock is an exclusive advisory lock (flock(2)) held on a file for the
// lifetime of the process. It is used to guarantee a single daemon instance per
// data directory: the kernel releases the lock automatically when the process
// exits, and Close releases it explicitly.
type FileLock struct {
	f         *os.File
	closeOnce sync.Once
	closeErr  error
}

// AcquireLock opens (creating with mode 0600 if needed) path and takes a
// non-blocking exclusive flock on it. It returns ErrLocked when the lock is
// already held by another process (or another open file description).
func AcquireLock(path string) (*FileLock, error) {
	if path == "" {
		return nil, errors.New("database: empty lock path")
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, FilePerm)
	if err != nil {
		return nil, fmt.Errorf("database: open lock %q: %w", path, err)
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrLocked
		}
		return nil, fmt.Errorf("database: flock %q: %w", path, err)
	}
	return &FileLock{f: f}, nil
}

// Close releases the lock and closes the underlying file. It is safe to call
// more than once.
func (l *FileLock) Close() error {
	if l == nil {
		return nil
	}
	l.closeOnce.Do(func() {
		// Unlocking is best-effort: closing the fd releases the flock anyway.
		_ = unix.Flock(int(l.f.Fd()), unix.LOCK_UN)
		l.closeErr = l.f.Close()
	})
	return l.closeErr
}
