package whatsapp

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
)

// pushQR delivers an item on the fake's current QR channel.
func pushQR(t *testing.T, fake *fakeClient, item whatsmeow.QRChannelItem) {
	t.Helper()
	select {
	case fake.qrChan <- item:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out pushing a QR channel item")
	}
}

// loginActive reports whether a QR login is currently tracked by the service.
func loginActive(svc *Service) bool {
	svc.loginMu.Lock()
	defer svc.loginMu.Unlock()
	return svc.loginActive
}

// TestStartLoginRestartAfterTimeout reproduces the reported bug: once a QR
// login times out, a new auth.start must open a fresh channel and emit another
// auth.qr instead of being rejected as login_in_progress.
func TestStartLoginRestartAfterTimeout(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("first StartLogin: %v", err)
	}

	// Terminal timeout: whatsmeow may or may not close the channel; the service
	// must stop the login by itself.
	pushQR(t, fake, whatsmeow.QRChannelItem{Event: "timeout"})
	readEvent(t, svc.Events(), EventAuthError)
	waitFor(t, time.Second, func() bool { return !loginActive(svc) })

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("second StartLogin after timeout: %v", err)
	}

	pushQR(t, fake, whatsmeow.QRChannelItem{
		Event:   whatsmeow.QRChannelEventCode,
		Code:    "2@NEWCODEAFTERTIMEOUT",
		Timeout: 60 * time.Second,
	})
	ev := readEvent(t, svc.Events(), EventAuthQR)
	if ev.Data["code"] != "2@NEWCODEAFTERTIMEOUT" {
		t.Fatalf("auth.qr after timeout = %v, want the new code", ev.Data["code"])
	}
}

// TestStartLoginRestartAfterCancel asserts the same recovery after an explicit
// auth.cancel.
func TestStartLoginRestartAfterCancel(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("first StartLogin: %v", err)
	}
	if err := svc.CancelLogin(); err != nil {
		t.Fatalf("CancelLogin: %v", err)
	}
	waitFor(t, time.Second, func() bool { return !loginActive(svc) })

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("second StartLogin after cancel: %v", err)
	}
	pushQR(t, fake, whatsmeow.QRChannelItem{
		Event:   whatsmeow.QRChannelEventCode,
		Code:    "2@NEWCODEAFTERCANCEL",
		Timeout: 20 * time.Second,
	})
	ev := readEvent(t, svc.Events(), EventAuthQR)
	if ev.Data["code"] != "2@NEWCODEAFTERCANCEL" {
		t.Fatalf("auth.qr after cancel = %v, want the new code", ev.Data["code"])
	}
}

// TestStartLoginRestartAfterErrorWithoutChannelClose covers the whatsmeow
// events that are delivered WITHOUT closing the QR channel (e.g. a phone with
// multi-device disabled). Eagerly stopping the login is what makes the next
// auth.start possible; relying on the channel close would leave the service
// stuck in login_active forever.
func TestStartLoginRestartAfterErrorWithoutChannelClose(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("first StartLogin: %v", err)
	}

	fake.qrChan <- whatsmeow.QRChannelItem{Event: "err-scanned-without-multidevice"}
	readEvent(t, svc.Events(), EventAuthError)
	// The channel is still open on purpose: only the eager terminal handling
	// can clear the login flag here.
	waitFor(t, time.Second, func() bool { return !loginActive(svc) })

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("second StartLogin after channel error: %v", err)
	}
	pushQR(t, fake, whatsmeow.QRChannelItem{
		Event:   whatsmeow.QRChannelEventCode,
		Code:    "2@NEWCODEAFTERERROR",
		Timeout: 20 * time.Second,
	})
	ev := readEvent(t, svc.Events(), EventAuthQR)
	if ev.Data["code"] != "2@NEWCODEAFTERERROR" {
		t.Fatalf("auth.qr after error = %v, want the new code", ev.Data["code"])
	}
}

// TestStartLoginConcurrentReturnsInProgress pins the contract: while a login is
// genuinely running, a second auth.start is refused (and logged) instead of
// silently racing the first one.
func TestStartLoginConcurrentReturnsInProgress(t *testing.T) {
	fake := newFakeClient()
	svc, logs := newTestService(t, fake)

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("first StartLogin: %v", err)
	}
	if err := svc.StartLogin(context.Background()); !errors.Is(err, ErrLoginInProgress) {
		t.Fatalf("concurrent StartLogin = %v, want ErrLoginInProgress", err)
	}
	if !strings.Contains(logs.String(), "auth.start refused") ||
		!strings.Contains(logs.String(), "login already active") {
		t.Fatalf("refusal was not logged at INFO: %s", logs.String())
	}
}

// TestStartLoginRefusalIsLogged asserts the diagnostic INFO line is written
// when a paired device makes auth.start fail.
func TestStartLoginRefusalIsLogged(t *testing.T) {
	fake := newFakeClient()
	svc, logs := newTestService(t, fake)
	jid := types.NewJID("5511999999999", types.DefaultUserServer)
	setDevice(svc, &store.Device{ID: &jid})

	if err := svc.StartLogin(context.Background()); !errors.Is(err, ErrAlreadyLoggedIn) {
		t.Fatalf("StartLogin = %v, want ErrAlreadyLoggedIn", err)
	}
	if !strings.Contains(logs.String(), "auth.start refused") ||
		!strings.Contains(logs.String(), "device already paired") {
		t.Fatalf("paired-device refusal was not logged: %s", logs.String())
	}
}
