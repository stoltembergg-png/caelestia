package whatsapp

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types/events"
)

// waitFor polls cond until it is true or the timeout elapses.
func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not satisfied before timeout")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestEmitConcurrentWithClose hammers emit while the service is closed. With
// the emitMu/emitClosed guard this must never panic (and must be clean under
// -race); late emits become no-ops.
func TestEmitConcurrentWithClose(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	drained := make(chan struct{})
	go func() {
		for range svc.Events() {
		}
		close(drained)
	}()

	stop := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					svc.emit("test.event", map[string]any{"k": "v"})
				}
			}
		}()
	}

	time.Sleep(10 * time.Millisecond)
	if err := svc.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	close(stop)
	wg.Wait()
	<-drained

	// After Close, emit must be a safe no-op (not a send on a closed channel).
	svc.emit("late.event", map[string]any{"k": "v"})
}

// TestCancelLogin starts a QR login and cancels it, asserting that
// consumeQRCodes is stopped (the whatsmeow channel is never closed on its own)
// and that a second cancel reports ErrNoLoginActive.
func TestCancelLogin(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	loginActive := func() bool {
		svc.loginMu.Lock()
		defer svc.loginMu.Unlock()
		return svc.loginActive
	}

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("StartLogin: %v", err)
	}
	if !loginActive() {
		t.Fatal("login is not active after StartLogin")
	}

	if err := svc.CancelLogin(); err != nil {
		t.Fatalf("CancelLogin: %v", err)
	}
	waitFor(t, time.Second, func() bool { return !loginActive() })

	if err := svc.CancelLogin(); !errors.Is(err, ErrNoLoginActive) {
		t.Fatalf("second CancelLogin = %v, want ErrNoLoginActive", err)
	}

	// A code pushed to the QR channel after cancel must not be consumed nor
	// turned into an auth.qr event.
	fake.qrChan <- whatsmeow.QRChannelItem{
		Event:   whatsmeow.QRChannelEventCode,
		Code:    "late-code",
		Timeout: time.Second,
	}
	deadline := time.After(150 * time.Millisecond)
	for {
		select {
		case ev := <-svc.Events():
			if ev.Name == EventAuthQR {
				t.Fatalf("auth.qr emitted after cancel: %+v", ev)
			}
		case <-deadline:
			return
		}
	}
}

// TestBanUntilClearedOnConnect verifies a reconnect drops the old ban.
func TestBanUntilClearedOnConnect(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.TemporaryBan{
		Code:   events.TempBanSentToTooManyPeople,
		Expire: time.Hour,
	})
	if st := svc.AuthStatus(); st.BanUntil.IsZero() {
		t.Fatal("BanUntil should be set after TemporaryBan")
	}

	svc.handleEvent(&events.Connected{})
	if st := svc.AuthStatus(); !st.BanUntil.IsZero() {
		t.Fatalf("BanUntil = %v after Connected, want zero", st.BanUntil)
	}
}

// TestBanUntilExpiredIgnored verifies AuthStatus forgets a lapsed ban.
func TestBanUntilExpiredIgnored(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.banMu.Lock()
	svc.banUntil = time.Now().Add(-time.Minute)
	svc.banMu.Unlock()

	if st := svc.AuthStatus(); !st.BanUntil.IsZero() {
		t.Fatalf("expired BanUntil = %v, want zero", st.BanUntil)
	}

	svc.banMu.Lock()
	defer svc.banMu.Unlock()
	if !svc.banUntil.IsZero() {
		t.Fatal("expired ban was not forgotten internally")
	}
}

// TestCloseWithPendingBanRecovery asserts Close waits for the tracked recovery
// goroutine (which unblocks via done) instead of leaking it past the event
// channel close.
func TestCloseWithPendingBanRecovery(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.TemporaryBan{
		Code:   events.TempBanSentToTooManyPeople,
		Expire: time.Hour,
	})

	done := make(chan error, 1)
	go func() { done <- svc.Close() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not wait for the ban recovery goroutine")
	}
}

// TestStartLoginConcurrentWithClose races a login start against shutdown. The
// wgMu/closing handshake must prevent "WaitGroup misuse" and the emit guard
// must prevent sends on the closed event channel.
func TestStartLoginConcurrentWithClose(t *testing.T) {
	for i := 0; i < 50; i++ {
		fake := newFakeClient()
		svc, _ := newTestService(t, fake)

		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			_ = svc.StartLogin(context.Background())
		}()
		go func() {
			defer wg.Done()
			_ = svc.Close()
		}()
		wg.Wait()
	}
}
