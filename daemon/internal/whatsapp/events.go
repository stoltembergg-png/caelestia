package whatsapp

import (
	"log/slog"
	"time"

	"go.mau.fi/whatsmeow/types/events"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// eventKind identifies the typed internal events produced by classification.
// These are the unit of work handed to the dispatcher (step 2.4 will persist
// the message/receipt/history ones).
type eventKind int

const (
	evtConnected eventKind = iota
	evtDisconnected
	evtKeepAliveTimeout
	evtKeepAliveRestored
	evtLoggedOut
	evtStreamReplaced
	evtClientOutdated
	evtTemporaryBan
	evtConnectFailure
	evtMessage
	evtReceipt
	evtHistorySync
)

func (k eventKind) String() string {
	switch k {
	case evtConnected:
		return "connected"
	case evtDisconnected:
		return "disconnected"
	case evtKeepAliveTimeout:
		return "keepalive_timeout"
	case evtKeepAliveRestored:
		return "keepalive_restored"
	case evtLoggedOut:
		return "logged_out"
	case evtStreamReplaced:
		return "stream_replaced"
	case evtClientOutdated:
		return "client_outdated"
	case evtTemporaryBan:
		return "temporary_ban"
	case evtConnectFailure:
		return "connect_failure"
	case evtMessage:
		return "message"
	case evtReceipt:
		return "receipt"
	case evtHistorySync:
		return "history_sync"
	default:
		return "unknown"
	}
}

// internalEvent is a classified whatsmeow event. It carries everything the
// dispatcher needs, so no whatsmeow types are touched outside the handler.
type internalEvent struct {
	kind    eventKind
	state   State
	reason  string
	summary string

	// Redacted identifiers used only for logging.
	chatJID   string
	senderJID string
	fromMe    bool

	banFor  time.Duration
	banCode string
}

// handleEvent is the single handler registered with whatsmeow. It must return
// quickly: it only classifies the event and enqueues it.
func (s *Service) handleEvent(evt any) {
	s.enqueue(classify(evt))
}

// classify maps a whatsmeow event to an internalEvent. It returns nil for
// events that are irrelevant or intentionally coalesced (Presence/ChatPresence).
func classify(evt any) *internalEvent {
	switch e := evt.(type) {
	case *events.Connected:
		return &internalEvent{kind: evtConnected, state: StateConnected, reason: "connected"}
	case *events.Disconnected:
		return &internalEvent{kind: evtDisconnected, state: StateDisconnected, reason: "disconnected"}
	case *events.KeepAliveTimeout:
		return &internalEvent{
			kind:   evtKeepAliveTimeout,
			state:  StateConnecting,
			reason: "keepalive timeout",
		}
	case *events.KeepAliveRestored:
		return &internalEvent{
			kind:   evtKeepAliveRestored,
			state:  StateConnected,
			reason: "keepalive restored",
		}
	case *events.LoggedOut:
		return &internalEvent{kind: evtLoggedOut, state: StateNeedsPairing, reason: "logged out"}
	case *events.StreamReplaced:
		return &internalEvent{kind: evtStreamReplaced, state: StateStreamReplaced, reason: "stream replaced"}
	case *events.ClientOutdated:
		return &internalEvent{kind: evtClientOutdated, state: StateOutdated, reason: "client outdated (405)"}
	case *events.TemporaryBan:
		return &internalEvent{
			kind:    evtTemporaryBan,
			state:   StateBanned,
			reason:  "temporary ban",
			banFor:  e.Expire,
			banCode: e.Code.String(),
		}
	case *events.ConnectFailure:
		switch {
		case e.Reason.IsLoggedOut():
			return &internalEvent{
				kind:   evtLoggedOut,
				state:  StateNeedsPairing,
				reason: "connect failure: " + e.Reason.String(),
			}
		case e.Reason == events.ConnectFailureClientOutdated:
			return &internalEvent{kind: evtClientOutdated, state: StateOutdated, reason: "client outdated (405)"}
		case e.Reason == events.ConnectFailureTempBanned:
			return &internalEvent{kind: evtTemporaryBan, state: StateBanned, reason: "temporary ban"}
		default:
			return &internalEvent{kind: evtConnectFailure, reason: "connect failure: " + e.Reason.String()}
		}
	case *events.Message:
		return &internalEvent{
			kind:      evtMessage,
			summary:   "message",
			chatJID:   e.Info.Chat.String(),
			senderJID: e.Info.Sender.String(),
			fromMe:    e.Info.IsFromMe,
		}
	case *events.Receipt:
		return &internalEvent{
			kind:      evtReceipt,
			summary:   "receipt",
			chatJID:   e.Chat.String(),
			senderJID: e.Sender.String(),
		}
	case *events.HistorySync:
		return &internalEvent{kind: evtHistorySync, summary: "history sync"}
	case *events.Presence, *events.ChatPresence:
		// Coalesced: presence/typing churn must never fill the queue.
		return nil
	default:
		return nil
	}
}

// process applies one classified event: state transitions, side effects and
// IPC events. Heavy work (message persistence in step 2.4, network calls) must
// stay out of the whatsmeow handler thread.
func (s *Service) process(ev *internalEvent) {
	if ev == nil {
		return
	}
	switch ev.kind {
	case evtMessage:
		s.logger.Info("whatsapp: message queued for persistence",
			slog.String("chat", logging.RedactJID(ev.chatJID)),
			slog.String("sender", logging.RedactJID(ev.senderJID)),
			slog.Bool("from_me", ev.fromMe))
	case evtReceipt, evtHistorySync:
		s.logger.Debug("whatsapp: event queued for persistence",
			slog.String("kind", ev.kind.String()))
	case evtConnectFailure:
		s.logger.Warn("whatsapp: connect failure", slog.String("reason", ev.reason))
	case evtLoggedOut:
		s.handleLoggedOut(ev)
	case evtStreamReplaced:
		// Another client connected with the same session. Reconnecting would
		// instantly be replaced again, so we stop and surface the state.
		s.setState(ev.state, ev.reason)
		s.logger.Error("whatsapp: stream replaced by another client; not reconnecting")
	case evtClientOutdated:
		s.setState(ev.state, ev.reason)
		s.logger.Error("whatsapp: client outdated (HTTP 405); update the daemon/whatsmeow")
	case evtTemporaryBan:
		s.handleTemporaryBan(ev)
	case evtConnected:
		// A successful connection clears any ban that had expired/been lifted.
		s.clearBan()
		if s.setState(ev.state, ev.reason) {
			s.emit(EventAuthConnected, s.connectedData())
		}
		s.sendPresence()
	case evtDisconnected:
		if s.isTerminal() {
			return
		}
		if s.setState(ev.state, ev.reason) {
			s.emit(EventAuthDisconnected, map[string]any{"reason": ev.reason})
		}
	case evtKeepAliveTimeout, evtKeepAliveRestored:
		if s.isTerminal() {
			return
		}
		s.setState(ev.state, ev.reason)
	}
}

// handleLoggedOut deletes the local session and returns the service to
// needs_pairing. whatsmeow may already have deleted the device (connect
// failure path); Device.Delete is idempotent.
func (s *Service) handleLoggedOut(ev *internalEvent) {
	s.logger.Warn("whatsapp: logged out; deleting local session",
		slog.String("reason", ev.reason))
	s.clearBan()
	if c := s.currentClient(); c != nil {
		if err := c.DeleteDevice(s.ctx); err != nil {
			s.logger.Warn("whatsapp: delete device failed", slog.String("error", err.Error()))
		}
	}
	s.emit(EventAuthDisconnected, map[string]any{"reason": ev.reason})
	s.setState(StateNeedsPairing, ev.reason)
}

// handleTemporaryBan records the ban and its expiry. When the ban expires and
// the state is still banned, it attempts a reconnect instead of waiting for the
// user to restart the daemon.
func (s *Service) handleTemporaryBan(ev *internalEvent) {
	reason := ev.reason
	if ev.banCode != "" {
		reason += ": " + ev.banCode
	}
	s.banMu.Lock()
	if ev.banFor > 0 {
		s.banUntil = time.Now().Add(ev.banFor)
	} else {
		s.banUntil = time.Time{}
	}
	expire := ev.banFor
	s.banMu.Unlock()

	s.setState(StateBanned, reason)
	s.logger.Error("whatsapp: temporary ban",
		slog.String("reason", reason),
		slog.Duration("expires_in", expire))

	if expire > 0 {
		s.scheduleBanRecovery(expire)
	}
}

func (s *Service) scheduleBanRecovery(after time.Duration) {
	// Tracked so Close waits for the timer goroutine instead of closing the
	// event channel underneath a late emit. goTracked refuses to register once
	// the service is shutting down.
	s.goTracked(func() {
		timer := time.NewTimer(after)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-s.done:
			return
		}
		if s.State() != StateBanned {
			return
		}
		s.logger.Info("whatsapp: temporary ban expired; reconnecting")
		if err := s.Connect(s.ctx); err != nil {
			s.logger.Warn("whatsapp: reconnect after ban failed", slog.String("error", err.Error()))
		}
	})
}
