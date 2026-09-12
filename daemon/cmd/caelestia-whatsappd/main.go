// Command caelestia-whatsappd is the native WhatsApp backend daemon.
//
// This step wires configuration, logging and the SQLite database only. IPC and
// whatsmeow are intentionally not part of it yet.
package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/config"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// version is the daemon build version (not a secret).
const version = "0.1.0-dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "caelestia-whatsappd:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	cfg, err := config.Load(args)
	if err != nil {
		return err
	}

	level, err := logging.ParseLevel(cfg.LogLevel)
	if err != nil {
		return err
	}
	logger := logging.New(os.Stderr, level)

	if err := ensureDir(cfg.DataDir); err != nil {
		return err
	}
	cacheDir := filepath.Join(cfg.DataDir, "cache")
	if err := ensureDir(cacheDir); err != nil {
		return err
	}

	dbPath := filepath.Join(cfg.DataDir, "whatsapp.db")
	db, err := database.Open(dbPath)
	if err != nil {
		return err
	}

	logger.Info("caelestia-whatsappd starting",
		slog.String("version", version),
		slog.String("data_dir", cfg.DataDir),
		slog.String("socket", cfg.Socket),
		slog.String("log_level", level.String()),
	)
	logger.Info("database ready", slog.String("path", dbPath))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)

	logger.Info("ready; waiting for shutdown signal")
	sig := <-sigCh
	logger.Info("shutdown signal received", slog.String("signal", sig.String()))

	if err := db.Close(); err != nil {
		return fmt.Errorf("close database: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

// ensureDir creates dir (if needed) and restricts it to the owner.
func ensureDir(dir string) error {
	if dir == "" {
		return fmt.Errorf("empty directory path")
	}
	if err := os.MkdirAll(dir, database.DirPerm); err != nil {
		return fmt.Errorf("create directory %q: %w", dir, err)
	}
	if err := os.Chmod(dir, database.DirPerm); err != nil {
		return fmt.Errorf("chmod directory %q: %w", dir, err)
	}
	return nil
}
