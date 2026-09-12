package whatsapp

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
)

// Authentication errors returned to the IPC layer.
var (
	// ErrAlreadyLoggedIn means a session already exists (or the client is
	// authenticated), so starting a QR login would be wrong.
	ErrAlreadyLoggedIn = errors.New("whatsapp: already logged in")
	// ErrLoginInProgress means a QR login is already running.
	ErrLoginInProgress = errors.New("whatsapp: a login is already in progress")
	// ErrNotPaired means there is no device to connect with.
	ErrNotPaired = errors.New("whatsapp: no paired device")
	// ErrNoLoginActive means auth.cancel was called with no QR login running.
	ErrNoLoginActive = errors.New("whatsapp: no login active")
	// errServiceClosing means StartLogin raced a service shutdown.
	errServiceClosing = errors.New("whatsapp: service is shutting down")
)

// CodeNoLoginActive is the stable IPC error code returned by auth.cancel when
// there is no login to cancel.
const CodeNoLoginActive = "no_login_active"

// StartLogin begins the QR pairing flow.
//
// It fails when a session already exists or another login is genuinely running.
// GetQRChannel MUST be called before Connect: it installs the handler that
// captures the codes from the upcoming connection. The raw code never reaches
// the logs — only the "qr emitted" line.
//
// Every refusal is logged at INFO (without secrets) so a stuck "Gerando
// código…" in the UI can be explained by the journal alone.
func (s *Service) StartLogin(ctx context.Context) error {
	s.loginMu.Lock()
	if s.loginActive {
		s.loginMu.Unlock()
		s.logger.Info("whatsapp: auth.start refused",
			slog.String("reason", "login already active"))
		return ErrLoginInProgress
	}
	if d := s.currentDevice(); d != nil && d.ID != nil {
		s.loginMu.Unlock()
		s.logger.Info("whatsapp: auth.start refused",
			slog.String("reason", "device already paired"))
		return ErrAlreadyLoggedIn
	}
	if c := s.currentClient(); c != nil && c.IsLoggedIn() {
		s.loginMu.Unlock()
		s.logger.Info("whatsapp: auth.start refused",
			slog.String("reason", "client already logged in"))
		return ErrAlreadyLoggedIn
	}
	// After a logout the old device is marked deleted and must not be reused;
	// recreate the client with a fresh, unpaired device.
	needRebuild := s.currentDevice() == nil || s.currentDevice().Deleted
	// The login context is derived from the service context, not from the
	// request context: the QR channel must outlive the IPC handler invocation,
	// yet still be canceled by auth.cancel/Logout/Close. whatsmeow does not
	// always close this channel (e.g. err-scanned-without-multidevice), so
	// cancellation is the only reliable way to stop consumeQRCodes.
	loginCtx, loginCancel := context.WithCancel(s.ctx)
	s.loginGen++
	gen := s.loginGen
	s.loginActive = true
	s.loginCancel = loginCancel
	s.loginMu.Unlock()

	if needRebuild {
		if err := s.rebuildClient(ctx); err != nil {
			s.stopLoginGen(gen)
			return err
		}
	}

	client := s.currentClient()
	if client == nil {
		s.stopLoginGen(gen)
		return ErrNotPaired
	}
	// A previous attempt (timeout/cancel/error) can leave the socket up:
	// whatsmeow's GetQRChannel refuses to run on a connected client, which
	// would make the retry fail with "open qr channel". Drop it first.
	if client.IsConnected() {
		client.Disconnect()
	}
	qrChan, err := client.GetQRChannel(loginCtx)
	if errors.Is(err, whatsmeow.ErrQRAlreadyConnected) {
		// Lost the race with whatsmeow's own disconnect; retry once.
		client.Disconnect()
		qrChan, err = client.GetQRChannel(loginCtx)
	}
	if err != nil {
		s.stopLoginGen(gen)
		if errors.Is(err, whatsmeow.ErrQRStoreContainsID) {
			s.logger.Info("whatsapp: auth.start refused",
				slog.String("reason", "device already paired"))
			return ErrAlreadyLoggedIn
		}
		return fmt.Errorf("whatsapp: open qr channel: %w", err)
	}

	s.setState(StateConnecting, "qr login started")
	if err := client.Connect(); err != nil {
		s.stopLoginGen(gen)
		return fmt.Errorf("whatsapp: connect for qr login: %w", err)
	}
	if !s.goTracked(func() { s.consumeQRCodes(gen, loginCtx, qrChan) }) {
		s.stopLoginGen(gen)
		return errServiceClosing
	}
	return nil
}

// consumeQRCodes translates the whatsmeow QR channel into IPC events until the
// channel closes, the login context is canceled or a terminal item ends the
// pairing. It carries the generation it was started with so that its deferred
// cleanup can never clear a newer login (see stopLoginGen).
func (s *Service) consumeQRCodes(gen uint64, ctx context.Context, qrChan <-chan whatsmeow.QRChannelItem) {
	defer s.stopLoginGen(gen)
	for {
		select {
		case <-ctx.Done():
			s.logger.Debug("whatsapp: qr login canceled")
			return
		case item, ok := <-qrChan:
			if !ok {
				return
			}
			// Both cases can be ready at once after a cancel; re-check so a
			// code that arrived concurrently with the cancellation is never
			// emitted.
			if ctx.Err() != nil {
				return
			}
			if s.handleQRItem(item) {
				return
			}
		}
	}
}

// handleQRItem classifies a single QR channel item and reports whether it
// terminates the login. Terminal outcomes stop the login eagerly instead of
// trusting the whatsmeow channel to close: some events (e.g.
// err-scanned-without-multidevice) are delivered without closing the channel,
// which previously left loginActive set and made every later auth.start return
// login_in_progress forever.
func (s *Service) handleQRItem(item whatsmeow.QRChannelItem) bool {
	switch item.Event {
	case whatsmeow.QRChannelEventCode:
		timeout := int(item.Timeout / time.Second)
		data := map[string]any{
			"code":    item.Code,
			"timeout": timeout,
		}
		// The frontend renders the QR from a PNG so it does not have to depend
		// on a QR library in QML. Both the raw code and its PNG are secrets and
		// must never reach the logs: on failure only a generic warning is
		// written (without the error, which could echo the content).
		if png, err := qrcode.Encode(item.Code, qrcode.Medium, 256); err != nil {
			s.logger.Warn("whatsapp: qr png generation failed")
		} else {
			data["png_base64"] = base64.StdEncoding.EncodeToString(png)
		}
		// Never log item.Code.
		s.logger.Info("whatsapp: qr emitted", slog.Int("timeout_seconds", timeout))
		s.emit(EventAuthQR, data)
		return false
	case "success":
		s.logger.Info("whatsapp: qr pairing succeeded")
		if s.setState(StateConnected, "pairing success") {
			s.emit(EventAuthConnected, s.connectedData())
		}
		s.sendPresence()
		return true
	case whatsmeow.QRChannelEventError:
		s.logger.Warn("whatsapp: qr pairing error",
			slog.String("error", qrErrorMessage(item.Error)))
		s.emit(EventAuthError, map[string]any{"message": qrErrorMessage(item.Error)})
		return true
	case "timeout":
		s.logger.Warn("whatsapp: qr pairing timed out")
		s.emit(EventAuthError, map[string]any{"message": "pairing timed out"})
		return true
	case "err-client-outdated":
		s.setState(StateOutdated, "client outdated during pairing")
		s.emit(EventAuthError, map[string]any{"message": "client outdated; update the daemon"})
		return true
	case "err-scanned-without-multidevice":
		s.emit(EventAuthError, map[string]any{
			"message": "QR scanned but multi-device is disabled on the phone",
		})
		return true
	default:
		s.logger.Debug("whatsapp: qr channel event", slog.String("event", item.Event))
		return false
	}
}

// stopLogin clears the active-login flag and cancels the in-flight login
// context, if any. It is unconditional and bumps the login generation so an
// in-flight consumeQRCodes cannot later undo a newer login. Safe to call more
// than once and from any goroutine.
func (s *Service) stopLogin() {
	s.loginMu.Lock()
	s.loginGen++
	cancel := s.loginCancel
	s.loginCancel = nil
	s.loginActive = false
	s.loginMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// stopLoginGen is the generation-guarded variant used by consumeQRCodes: it
// only clears/cancels the login it was created for. A stale consumer whose
// terminal item arrived after a newer auth.start is a no-op.
func (s *Service) stopLoginGen(gen uint64) {
	s.loginMu.Lock()
	if s.loginGen != gen {
		s.loginMu.Unlock()
		return
	}
	cancel := s.loginCancel
	s.loginCancel = nil
	s.loginActive = false
	s.loginMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// CancelLogin aborts an in-progress QR login (IPC `auth.cancel`). It returns
// ErrNoLoginActive when no login is running.
func (s *Service) CancelLogin() error {
	s.loginMu.Lock()
	active := s.loginActive
	s.loginGen++
	cancel := s.loginCancel
	s.loginCancel = nil
	s.loginActive = false
	s.loginMu.Unlock()
	if !active {
		return ErrNoLoginActive
	}
	if cancel != nil {
		cancel()
	}
	return nil
}

// Logout unlinks the device, deletes the local session and returns to
// needs_pairing. A failed unlink request does not prevent the local reset so
// the user can always start a fresh pairing; the failure is logged.
func (s *Service) Logout(ctx context.Context) error {
	s.stopLogin()
	s.clearBan()

	client := s.currentClient()
	if client == nil {
		s.setState(StateNeedsPairing, "logout")
		return nil
	}

	logoutErr := client.Logout(ctx)
	if logoutErr != nil {
		s.logger.Warn("whatsapp: logout request failed", slog.String("error", logoutErr.Error()))
	}
	if err := client.DeleteDevice(ctx); err != nil {
		s.logger.Warn("whatsapp: delete device failed", slog.String("error", err.Error()))
		if logoutErr != nil {
			return fmt.Errorf("whatsapp: logout: %w", logoutErr)
		}
	}

	s.emit(EventAuthDisconnected, map[string]any{"reason": "logout"})
	s.setState(StateNeedsPairing, "logout")
	return nil
}

func qrErrorMessage(err error) string {
	if err == nil {
		return "pairing error"
	}
	return err.Error()
}
