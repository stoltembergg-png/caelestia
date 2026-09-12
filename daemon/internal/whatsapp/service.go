// Package whatsapp wraps the whatsmeow client used by the daemon.
//
// It owns the SQLite-backed whatsmeow store (sharing the daemon's *sql.DB),
// the connection/authentication state machine and the single, non-blocking
// whatsmeow event handler described in docs/ARQUITETURA.md §3.1/§3.2/§3.4.
//
// Security rule: QR codes, session keys and tokens are never written to the
// logs. In particular, the whatsmeow debug/info logs (which include the raw QR
// code) are deliberately dropped; only warnings and errors are forwarded.
package whatsapp

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// eventBufferSize is the capacity of the internal event queues. The handler
// never performs I/O, it only classifies and enqueues.
const eventBufferSize = 1024

// State is the connection/authentication state exposed over IPC.
type State string

// Possible states. The values are part of the IPC contract and must stay stable.
const (
	StateDisconnected   State = "disconnected"
	StateConnecting     State = "connecting"
	StateConnected      State = "connected"
	StateNeedsPairing   State = "needs_pairing"
	StateLoggedOut      State = "logged_out"
	StateBanned         State = "banned"
	StateOutdated       State = "outdated"
	StateStreamReplaced State = "stream_replaced"
)

// Event names published by the service. main.go forwards these to the IPC
// server with Broadcast.
const (
	EventAuthQR            = "auth.qr"
	EventAuthConnected     = "auth.connected"
	EventAuthDisconnected  = "auth.disconnected"
	EventAuthError         = "auth.error"
	EventConnectionUpdated = "connection.updated"
)

// Event is an internal, already-redacted event ready to be broadcast over IPC.
type Event struct {
	Name string
	Data map[string]any
}

// waClient is the minimal surface of *whatsmeow.Client used by the service. It
// exists so that the state machine and the event classification can be tested
// without a network connection (see service_test.go).
type waClient interface {
	AddEventHandler(handler whatsmeow.EventHandler) uint32
	Connect() error
	Disconnect()
	Logout(ctx context.Context) error
	GetQRChannel(ctx context.Context) (<-chan whatsmeow.QRChannelItem, error)
	IsConnected() bool
	IsLoggedIn() bool
	SendPresence(ctx context.Context, state types.Presence) error
	// DeleteDevice removes the local session; it is used for external logouts.
	DeleteDevice(ctx context.Context) error
}

// realClient adapts *whatsmeow.Client to waClient, adding DeleteDevice.
type realClient struct {
	*whatsmeow.Client
}

func (c *realClient) DeleteDevice(ctx context.Context) error {
	if c == nil || c.Client == nil || c.Store == nil {
		return nil
	}
	return c.Store.Delete(ctx)
}

// Service owns the whatsmeow client and the daemon-side state machine.
type Service struct {
	logger *slog.Logger
	waLog  waLog.Logger

	clientFactory func(*store.Device, waLog.Logger) waClient
	firstDevice   func(context.Context) (*store.Device, error)

	// mu guards client and device, which are swapped when the previous device
	// is deleted and a fresh (unpaired) one has to be created.
	mu     sync.RWMutex
	client waClient
	device *store.Device

	stateMu        sync.RWMutex
	state          State
	onStateChanged func(State)

	loginMu     sync.Mutex
	loginActive bool

	banMu    sync.Mutex
	banUntil time.Time

	inbox     chan *internalEvent
	ipcEvents chan Event

	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	wg     sync.WaitGroup

	closeOnce sync.Once

	// syncDispatch is a test seam: when set, events are processed inline so
	// tests do not have to poll for state transitions.
	syncDispatch bool
}

// New opens the whatsmeow store inside the same SQLite database used by the
// daemon, upgrades it, loads the first device and builds the client. If a
// device is already paired it connects in the background.
func New(ctx context.Context, db *sql.DB, logger *slog.Logger) (*Service, error) {
	if db == nil {
		return nil, errors.New("whatsapp: nil database handle")
	}
	if logger == nil {
		logger = slog.Default()
	}

	svcCtx, cancel := context.WithCancel(ctx)
	s := &Service{
		logger: logger,
		waLog:  newWALogger(logger),
		state:  StateDisconnected,

		clientFactory: func(d *store.Device, l waLog.Logger) waClient {
			c := whatsmeow.NewClient(d, l)
			c.EnableAutoReconnect = true
			// Reconnect when the very first connection attempt fails with a
			// transient network error, so a boot without connectivity is not
			// fatal.
			c.InitialAutoReconnect = true
			return &realClient{Client: c}
		},

		inbox:     make(chan *internalEvent, eventBufferSize),
		ipcEvents: make(chan Event, eventBufferSize),
		ctx:       svcCtx,
		cancel:    cancel,
		done:      make(chan struct{}),
	}

	container := sqlstore.NewWithDB(db, "sqlite", s.waLog)
	if err := container.Upgrade(s.ctx); err != nil {
		cancel()
		return nil, fmt.Errorf("whatsapp: upgrade sqlstore: %w", err)
	}
	s.firstDevice = container.GetFirstDevice

	device, err := container.GetFirstDevice(s.ctx)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("whatsapp: get first device: %w", err)
	}
	s.device = device
	s.client = s.clientFactory(device, s.waLog)
	s.client.AddEventHandler(s.handleEvent)

	s.wg.Add(1)
	go s.dispatchLoop()

	if device.ID != nil {
		// Connect in the background so a slow/unreachable network never delays
		// the daemon's startup. Connect() itself handles the state transitions.
		go func() {
			if err := s.Connect(s.ctx); err != nil {
				s.logger.Warn("whatsapp: initial connect failed",
					slog.String("error", err.Error()))
			}
		}()
	} else {
		s.setState(StateNeedsPairing, "no device paired")
	}

	return s, nil
}

// State returns the current connection/authentication state.
func (s *Service) State() State {
	s.stateMu.RLock()
	defer s.stateMu.RUnlock()
	return s.state
}

// OnStateChanged registers a callback invoked (outside the state lock) whenever
// the state actually changes. Passing nil clears it.
func (s *Service) OnStateChanged(fn func(State)) {
	s.stateMu.Lock()
	s.onStateChanged = fn
	s.stateMu.Unlock()
}

// Events returns the stream of IPC-ready events. The channel is closed by
// Close.
func (s *Service) Events() <-chan Event { return s.ipcEvents }

// IsLoggedIn reports whether whatsmeow considers the client authenticated.
func (s *Service) IsLoggedIn() bool {
	if c := s.currentClient(); c != nil {
		return c.IsLoggedIn()
	}
	return false
}

// AuthStatus is a snapshot of the authentication state for the IPC status
// method.
type AuthStatus struct {
	State    State
	LoggedIn bool
	JID      string
	PushName string
	BanUntil time.Time
}

// AuthStatus returns the current authentication snapshot.
func (s *Service) AuthStatus() AuthStatus {
	st := AuthStatus{State: s.State(), LoggedIn: s.IsLoggedIn()}
	if d := s.currentDevice(); d != nil {
		if d.ID != nil {
			st.JID = d.ID.String()
		}
		st.PushName = d.PushName
	}
	s.banMu.Lock()
	st.BanUntil = s.banUntil
	s.banMu.Unlock()
	return st
}

// Connect connects a paired device. It returns ErrNotPaired when there is no
// usable session; network errors are returned to the caller but only downgrade
// the state to disconnected (the daemon keeps running).
func (s *Service) Connect(ctx context.Context) error {
	d := s.currentDevice()
	if d == nil || d.ID == nil || d.Deleted {
		return ErrNotPaired
	}
	c := s.currentClient()
	if c == nil {
		return ErrNotPaired
	}

	s.setState(StateConnecting, "connect requested")
	if err := c.Connect(); err != nil {
		s.logger.Warn("whatsapp: connect failed", slog.String("error", err.Error()))
		if !s.isTerminal() {
			s.setState(StateDisconnected, "connect failed")
		}
		return err
	}
	return nil
}

// Disconnect closes the websocket without touching the stored session.
func (s *Service) Disconnect() {
	if c := s.currentClient(); c != nil {
		c.Disconnect()
	}
}

// Close disconnects the client and stops the internal dispatcher. It never
// closes the shared *sql.DB: that handle belongs to the caller.
func (s *Service) Close() error {
	s.closeOnce.Do(func() {
		close(s.done)
		s.cancel()
		s.Disconnect()
		s.wg.Wait()
		close(s.ipcEvents)
	})
	return nil
}

// dispatchLoop consumes classified events. It is the only place where state
// transitions and side effects happen, keeping the whatsmeow handler fast.
func (s *Service) dispatchLoop() {
	defer s.wg.Done()
	for {
		select {
		case <-s.done:
			return
		case ev := <-s.inbox:
			s.process(ev)
		}
	}
}

// enqueue hands a classified event to the dispatcher. The fast path is a
// non-blocking channel send; only if the buffer is full does it wait for room,
// so Message/Receipt/HistorySync are never silently dropped. Presence and
// ChatPresence are coalesced (dropped) during classification, before this point.
func (s *Service) enqueue(ev *internalEvent) {
	if ev == nil {
		return
	}
	if s.syncDispatch {
		s.process(ev)
		return
	}
	select {
	case s.inbox <- ev:
		return
	default:
	}
	select {
	case s.inbox <- ev:
	case <-s.done:
	}
}

// setState updates the state, notifies the callback and emits a
// connection.updated event. It returns true when the state actually changed.
func (s *Service) setState(next State, reason string) bool {
	s.stateMu.Lock()
	prev := s.state
	if prev == next {
		s.stateMu.Unlock()
		return false
	}
	s.state = next
	cb := s.onStateChanged
	s.stateMu.Unlock()

	s.logger.Info("whatsapp: state changed",
		slog.String("from", string(prev)),
		slog.String("to", string(next)),
		slog.String("reason", reason))
	if cb != nil {
		cb(next)
	}
	s.emit(EventConnectionUpdated, map[string]any{
		"state": string(next),
		"since": strconv.FormatInt(time.Now().UnixMilli(), 10),
	})
	return true
}

// emit queues an IPC event without blocking forever: Close unblocks it.
func (s *Service) emit(name string, data map[string]any) {
	ev := Event{Name: name, Data: data}
	select {
	case s.ipcEvents <- ev:
	case <-s.done:
	}
}

// isTerminal reports whether the current state is a permanent outcome that a
// later Disconnected/KeepAlive event must not downgrade.
func (s *Service) isTerminal() bool {
	switch s.State() {
	case StateBanned, StateOutdated, StateStreamReplaced, StateNeedsPairing, StateLoggedOut:
		return true
	default:
		return false
	}
}

func (s *Service) currentClient() waClient {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.client
}

func (s *Service) currentDevice() *store.Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.device
}

// connectedData builds the payload for auth.connected. The JID is the user's
// own identifier, not a credential.
func (s *Service) connectedData() map[string]any {
	data := map[string]any{}
	if d := s.currentDevice(); d != nil {
		if d.ID != nil {
			data["jid"] = d.ID.String()
		}
		if d.PushName != "" {
			data["push_name"] = d.PushName
		}
	}
	return data
}

// sendPresence announces the device as available right after connecting.
func (s *Service) sendPresence() {
	c := s.currentClient()
	if c == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(s.ctx, 30*time.Second)
		defer cancel()
		if err := c.SendPresence(ctx, types.PresenceAvailable); err != nil {
			s.logger.Debug("whatsapp: send presence failed",
				slog.String("error", err.Error()))
		}
	}()
}

// rebuildClient discards the current client and creates a fresh one bound to a
// new device. It is needed after the previous device was deleted (logout or an
// external LoggedOut), because whatsmeow refuses to reuse a deleted device.
func (s *Service) rebuildClient(ctx context.Context) error {
	s.mu.Lock()
	old := s.client
	s.mu.Unlock()
	if old != nil {
		old.Disconnect()
	}

	device, err := s.firstDevice(ctx)
	if err != nil {
		return fmt.Errorf("whatsapp: get device: %w", err)
	}
	c := s.clientFactory(device, s.waLog)
	c.AddEventHandler(s.handleEvent)

	s.mu.Lock()
	s.device = device
	s.client = c
	s.mu.Unlock()
	return nil
}

// waLogAdapter forwards only warnings and errors from whatsmeow to our
// structured logger. Debug (which contains the raw QR code) and info are
// intentionally dropped. Forwarded messages have JID user parts redacted.
type waLogAdapter struct {
	logger *slog.Logger
	module string
}

var _ waLog.Logger = waLogAdapter{}

// jidUserRegex matches the user (and optional device) part of a JID so it can
// be redacted before the message reaches the logs.
var jidUserRegex = regexp.MustCompile(`[0-9]+(?::[0-9]+)?@`)

func newWALogger(logger *slog.Logger) waLog.Logger {
	return waLogAdapter{logger: logger}
}

func (l waLogAdapter) Errorf(msg string, args ...any) {
	l.logger.Error("whatsmeow: "+formatWA(msg, args), slog.String("module", l.module))
}

func (l waLogAdapter) Warnf(msg string, args ...any) {
	l.logger.Warn("whatsmeow: "+formatWA(msg, args), slog.String("module", l.module))
}

func (l waLogAdapter) Infof(string, ...any)  {}
func (l waLogAdapter) Debugf(string, ...any) {}

func (l waLogAdapter) Sub(module string) waLog.Logger {
	return waLogAdapter{logger: l.logger, module: module}
}

// formatWA renders a whatsmeow log line and redacts JID user parts.
func formatWA(msg string, args []any) string {
	if len(args) > 0 {
		msg = fmt.Sprintf(msg, args...)
	}
	return jidUserRegex.ReplaceAllString(msg, "***@")
}
