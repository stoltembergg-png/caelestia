package whatsapp

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

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
)

// StartLogin begins the QR pairing flow.
//
// It fails when a session already exists. GetQRChannel MUST be called before
// Connect: it installs the handler that captures the codes from the upcoming
// connection. The raw code never reaches the logs — only the "qr emitted" line.
func (s *Service) StartLogin(ctx context.Context) error {
	s.loginMu.Lock()
	if s.loginActive {
		s.loginMu.Unlock()
		return ErrLoginInProgress
	}
	if d := s.currentDevice(); d != nil && d.ID != nil {
		s.loginMu.Unlock()
		return ErrAlreadyLoggedIn
	}
	if c := s.currentClient(); c != nil && c.IsLoggedIn() {
		s.loginMu.Unlock()
		return ErrAlreadyLoggedIn
	}
	// After a logout the old device is marked deleted and must not be reused;
	// recreate the client with a fresh, unpaired device.
	needRebuild := s.currentDevice() == nil || s.currentDevice().Deleted
	s.loginActive = true
	s.loginMu.Unlock()

	if needRebuild {
		if err := s.rebuildClient(ctx); err != nil {
			s.setLoginActive(false)
			return err
		}
	}

	client := s.currentClient()
	if client == nil {
		s.setLoginActive(false)
		return ErrNotPaired
	}
	qrChan, err := client.GetQRChannel(ctx)
	if err != nil {
		s.setLoginActive(false)
		return fmt.Errorf("whatsapp: open qr channel: %w", err)
	}

	s.setState(StateConnecting, "qr login started")
	if err := client.Connect(); err != nil {
		s.setLoginActive(false)
		return fmt.Errorf("whatsapp: connect for qr login: %w", err)
	}
	go s.consumeQRCodes(qrChan)
	return nil
}

// consumeQRCodes translates the whatsmeow QR channel into IPC events.
func (s *Service) consumeQRCodes(qrChan <-chan whatsmeow.QRChannelItem) {
	defer s.setLoginActive(false)
	for item := range qrChan {
		switch item.Event {
		case whatsmeow.QRChannelEventCode:
			timeout := int(item.Timeout / time.Second)
			// Never log item.Code.
			s.logger.Info("whatsapp: qr emitted", slog.Int("timeout_seconds", timeout))
			s.emit(EventAuthQR, map[string]any{
				"code":    item.Code,
				"timeout": timeout,
			})
		case "success":
			s.logger.Info("whatsapp: qr pairing succeeded")
			if s.setState(StateConnected, "pairing success") {
				s.emit(EventAuthConnected, s.connectedData())
			}
			s.sendPresence()
		case whatsmeow.QRChannelEventError:
			s.logger.Warn("whatsapp: qr pairing error",
				slog.String("error", qrErrorMessage(item.Error)))
			s.emit(EventAuthError, map[string]any{"message": qrErrorMessage(item.Error)})
		case "timeout":
			s.logger.Warn("whatsapp: qr pairing timed out")
			s.emit(EventAuthError, map[string]any{"message": "pairing timed out"})
		case "err-client-outdated":
			s.setState(StateOutdated, "client outdated during pairing")
			s.emit(EventAuthError, map[string]any{"message": "client outdated; update the daemon"})
		case "err-scanned-without-multidevice":
			s.emit(EventAuthError, map[string]any{
				"message": "QR scanned but multi-device is disabled on the phone",
			})
		default:
			s.logger.Debug("whatsapp: qr channel event", slog.String("event", item.Event))
		}
	}
}

func (s *Service) setLoginActive(active bool) {
	s.loginMu.Lock()
	s.loginActive = active
	s.loginMu.Unlock()
}

// Logout unlinks the device, deletes the local session and returns to
// needs_pairing. A failed unlink request does not prevent the local reset so
// the user can always start a fresh pairing; the failure is logged.
func (s *Service) Logout(ctx context.Context) error {
	s.setLoginActive(false)

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
