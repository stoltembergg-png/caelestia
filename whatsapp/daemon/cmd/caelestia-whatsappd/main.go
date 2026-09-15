// Command caelestia-whatsappd is the native WhatsApp backend daemon.
//
// It wires configuration, logging, the SQLite database, the whatsmeow service
// (connection/authentication state machine + event pump) and the IPC server.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/config"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/whatsapp"
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

	// Single-instance guard: take an advisory flock on <data-dir>/daemon.lock
	// *before* touching the database or the socket. The fd stays open for the
	// whole process life; the kernel releases it on exit (and Close unlocks
	// explicitly). Two daemons pointed at the same data-dir would otherwise
	// fight over SQLite/WAL and the socket.
	lockPath := filepath.Join(cfg.DataDir, "daemon.lock")
	lock, err := database.AcquireLock(lockPath)
	if err != nil {
		if errors.Is(err, database.ErrLocked) {
			return fmt.Errorf("outra instância já usa este data-dir %q (daemon.lock preso)", cfg.DataDir)
		}
		return err
	}
	defer func() {
		if cerr := lock.Close(); cerr != nil {
			logger.Warn("close data-dir lock", slog.String("error", cerr.Error()))
		}
	}()

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
	repo := database.NewRepo(db)

	// The whatsmeow store shares the daemon's SQLite handle. Service.New runs
	// container.Upgrade and loads the first device, attaching the state
	// handler. It does not connect: persistence is attached next and the
	// background auto-connect is triggered by Service.Start below, so no
	// handler can miss the first connection.
	svc, err := whatsapp.New(context.Background(), db, logger)
	if err != nil {
		_ = db.Close()
		return err
	}
	logger.Info("whatsapp service ready", slog.String("state", string(svc.State())))

	// Persistence pipeline: the Persister is owned by the service, which
	// re-registers it on every client it builds (e.g. after a re-pair).
	persister := svc.EnablePersistence(repo, cfg.DataDir)

	startedAt := time.Now()
	ipcServer := ipc.NewServer(cfg.Socket, logger)
	registerHandlers(ipcServer, svc, repo, cfg, logger, startedAt)

	// Domain events (message.received, message.updated, receipt.updated,
	// chat.updated) are produced by the persistence worker only after the row
	// is committed to SQLite (persist-before-publish). Binding the hook
	// directly to Broadcast keeps a single publisher path: the pump below
	// forwards the auth/connection events from the service. On shutdown the
	// persister is closed and drained *before* the IPC server, so events
	// accepted by the worker are still broadcast while clients are connected.
	persister.OnDomainEvent(ipcServer.Broadcast)

	if err := ipcServer.Start(); err != nil {
		_ = svc.Close()
		_ = db.Close()
		return err
	}
	logger.Info("ipc server listening", slog.String("socket", cfg.Socket))

	// Event pump: service -> IPC broadcast. It ends when the service closes its
	// Events channel on shutdown.
	pumpDone := make(chan struct{})
	go func() {
		defer close(pumpDone)
		for ev := range svc.Events() {
			ipcServer.Broadcast(ev.Name, ev.Data)
		}
	}()

	// Auto-connect only now: the state handler (New), the persistence handler
	// (EnablePersistence) and the event pump are all in place, so the first
	// connection cannot outrun them.
	if err := svc.Start(context.Background()); err != nil {
		logger.Warn("whatsapp: start failed", slog.String("error", err.Error()))
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)

	logger.Info("ready; waiting for shutdown signal")
	sig := <-sigCh
	logger.Info("shutdown signal received", slog.String("signal", sig.String()))

	// Shutdown order matters: stop the persistence worker first (drain pending
	// writes), then the whatsmeow service (disconnect, stop producers and close
	// its event channel), then the IPC server *before* waiting for the pump so
	// a client that stopped reading cannot hold the pump hostage, and only at
	// the end the shared database. The data-dir flock is released by the
	// deferred lock.Close.
	persister.Close()
	if err := svc.Close(); err != nil {
		logger.Warn("close whatsapp service", slog.String("error", err.Error()))
	}

	if err := ipcServer.Close(); err != nil {
		return fmt.Errorf("close ipc server: %w", err)
	}
	logger.Info("ipc server stopped")

	<-pumpDone
	logger.Info("whatsapp service stopped")

	if err := db.Close(); err != nil {
		return fmt.Errorf("close database: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

// registerHandlers installs the ping/status/auth methods and the
// chats/messages/contacts method set.
func registerHandlers(s *ipc.Server, svc *whatsapp.Service, repo *database.Repo, cfg *config.Config, logger *slog.Logger, startedAt time.Time) {
	whatsapp.NewMethods(svc, repo, cfg.DataDir, logger).Register(s)

	s.Register("ping", func(_ context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		return map[string]any{"pong": true, "version": version}, nil
	})

	s.Register("status", func(_ context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		st := svc.AuthStatus()
		return map[string]any{
			"version":        version,
			"uptime_seconds": int64(time.Since(startedAt).Seconds()),
			"data_dir":       cfg.DataDir,
			"socket":         cfg.Socket,
			"connection":     map[string]any{"state": string(st.State)},
			"auth":           authResult(st),
		}, nil
	})

	s.Register("auth.start", func(ctx context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		// StartLogin derives its own login context from the service context, so
		// the QR channel outlives this handler and can be canceled by
		// auth.cancel/logout/shutdown. The request ctx is only used for the
		// optional client rebuild.
		if err := svc.StartLogin(ctx); err != nil {
			return nil, authError(err)
		}
		return map[string]any{"started": true}, nil
	})

	s.Register("auth.cancel", func(_ context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		if err := svc.CancelLogin(); err != nil {
			return nil, authError(err)
		}
		return map[string]any{"canceled": true}, nil
	})

	s.Register("auth.status", func(_ context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		return authResult(svc.AuthStatus()), nil
	})

	s.Register("auth.logout", func(ctx context.Context, _ *ipc.Client, _ json.RawMessage) (any, *ipc.Error) {
		logoutCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		if err := svc.Logout(logoutCtx); err != nil {
			return nil, &ipc.Error{Code: ipc.ErrorInternal, Message: err.Error()}
		}
		return map[string]any{
			"logged_out": true,
			"state":      string(svc.State()),
		}, nil
	})
}

// authResult builds the auth.status payload. jid/push_name are only present
// when a device is known.
func authResult(st whatsapp.AuthStatus) map[string]any {
	out := map[string]any{
		"state":     string(st.State),
		"logged_in": st.LoggedIn,
	}
	if st.JID != "" {
		out["jid"] = st.JID
	}
	if st.PushName != "" {
		out["push_name"] = st.PushName
	}
	if !st.BanUntil.IsZero() {
		out["banned_until"] = st.BanUntil.UTC().Format(time.RFC3339)
	}
	return out
}

// authError maps service errors to protocol errors without leaking internals.
func authError(err error) *ipc.Error {
	switch {
	case errors.Is(err, whatsapp.ErrAlreadyLoggedIn), errors.Is(err, whatsapp.ErrLoginInProgress):
		return &ipc.Error{Code: ipc.ErrorInvalidRequest, Message: err.Error()}
	case errors.Is(err, whatsapp.ErrNoLoginActive):
		return &ipc.Error{Code: whatsapp.CodeNoLoginActive, Message: err.Error()}
	default:
		return &ipc.Error{Code: ipc.ErrorInternal, Message: err.Error()}
	}
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
