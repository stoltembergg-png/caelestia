package whatsapp

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// fakeClient implements waClient without any network access. It records the
// calls the service makes and exposes the QR channel the test can push into.
type fakeClient struct {
	mu sync.Mutex

	handlers     []whatsmeow.EventHandler
	connected    bool
	loggedIn     bool
	deleted      bool
	disconnected bool

	getQRCalled     bool
	connectCalled   bool
	connectCount    int
	qrBeforeConnect bool

	// handlerCountAtConnect records how many handlers were registered when
	// Connect ran, so tests can assert handlers-before-Connect.
	handlerCountAtConnect int

	qrChan     chan whatsmeow.QRChannelItem
	qrCloseOne sync.Once
	presence   []types.Presence

	connectErr error
	logoutErr  error
}

func newFakeClient() *fakeClient {
	return &fakeClient{qrChan: make(chan whatsmeow.QRChannelItem, 8)}
}

func (f *fakeClient) AddEventHandler(h whatsmeow.EventHandler) uint32 {
	f.mu.Lock()
	f.handlers = append(f.handlers, h)
	n := len(f.handlers)
	f.mu.Unlock()
	return uint32(n)
}

func (f *fakeClient) handlerCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.handlers)
}

// dispatchEvent delivers evt to every registered handler, mimicking whatsmeow.
func (f *fakeClient) dispatchEvent(evt any) {
	f.mu.Lock()
	handlers := append([]whatsmeow.EventHandler(nil), f.handlers...)
	f.mu.Unlock()
	for _, h := range handlers {
		h(evt)
	}
}

// connectInfo returns whether Connect ran and how many handlers were attached
// at that moment.
func (f *fakeClient) connectInfo() (called bool, handlersAtConnect int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.connectCalled, f.handlerCountAtConnect
}

func (f *fakeClient) Connect() error {
	f.mu.Lock()
	f.connectCalled = true
	f.connectCount++
	f.handlerCountAtConnect = len(f.handlers)
	f.connected = true
	err := f.connectErr
	f.mu.Unlock()
	return err
}

func (f *fakeClient) Disconnect() {
	f.mu.Lock()
	f.disconnected = true
	f.connected = false
	f.mu.Unlock()
}

func (f *fakeClient) Logout(context.Context) error {
	f.mu.Lock()
	f.deleted = true
	f.loggedIn = false
	err := f.logoutErr
	f.mu.Unlock()
	return err
}

func (f *fakeClient) GetQRChannel(context.Context) (<-chan whatsmeow.QRChannelItem, error) {
	f.mu.Lock()
	f.getQRCalled = true
	f.qrBeforeConnect = !f.connectCalled
	f.mu.Unlock()
	return f.qrChan, nil
}

func (f *fakeClient) IsConnected() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.connected
}

func (f *fakeClient) IsLoggedIn() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.loggedIn
}

func (f *fakeClient) SendPresence(_ context.Context, state types.Presence) error {
	f.mu.Lock()
	f.presence = append(f.presence, state)
	f.mu.Unlock()
	return nil
}

func (f *fakeClient) DeleteDevice(context.Context) error {
	f.mu.Lock()
	f.deleted = true
	f.mu.Unlock()
	return nil
}

func (f *fakeClient) wasDeleted() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.deleted
}

func (f *fakeClient) gotQRCodesBeforeConnect() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.getQRCalled && f.qrBeforeConnect
}

func (f *fakeClient) closeQR() {
	f.qrCloseOne.Do(func() { close(f.qrChan) })
}

// newTestService builds a Service with a fake client and synchronous dispatch,
// so tests observe transitions deterministically.
func newTestService(t *testing.T, fake *fakeClient) (*Service, *bytes.Buffer) {
	t.Helper()

	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))

	ctx, cancel := context.WithCancel(context.Background())
	svc := &Service{
		logger: logger,
		waLog:  waLog.Noop,
		state:  StateDisconnected,

		client: fake,
		device: &store.Device{},

		inbox:     make(chan *internalEvent, eventBufferSize),
		ipcEvents: make(chan Event, eventBufferSize),

		ctx:    ctx,
		cancel: cancel,
		done:   make(chan struct{}),

		syncDispatch: true,
	}
	svc.firstDevice = func(context.Context) (*store.Device, error) {
		return &store.Device{}, nil
	}
	svc.clientFactory = func(*store.Device, waLog.Logger) waClient { return fake }
	// Mirror the production wiring: the service registers its handlers through
	// the shared attachHandlers path when a client is built.
	svc.attachHandlers(fake)

	t.Cleanup(func() {
		fake.closeQR()
		_ = svc.Close()
	})
	return svc, &buf
}

func setDevice(svc *Service, d *store.Device) {
	svc.mu.Lock()
	svc.device = d
	svc.mu.Unlock()
}

// readEvent waits for the next event with the given name, failing on timeout.
func readEvent(t *testing.T, ch <-chan Event, name string) Event {
	t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case ev := <-ch:
			if ev.Name == name {
				return ev
			}
		case <-timeout:
			t.Fatalf("timed out waiting for event %q", name)
		}
	}
}

func TestStateTransitionsConnectedDisconnected(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	var mu sync.Mutex
	var states []State
	svc.OnStateChanged(func(s State) {
		mu.Lock()
		states = append(states, s)
		mu.Unlock()
	})

	svc.handleEvent(&events.Connected{})
	if got := svc.State(); got != StateConnected {
		t.Fatalf("after Connected: state = %q, want %q", got, StateConnected)
	}
	readEvent(t, svc.Events(), EventConnectionUpdated)
	readEvent(t, svc.Events(), EventAuthConnected)

	svc.handleEvent(&events.Disconnected{})
	if got := svc.State(); got != StateDisconnected {
		t.Fatalf("after Disconnected: state = %q, want %q", got, StateDisconnected)
	}
	readEvent(t, svc.Events(), EventConnectionUpdated)
	readEvent(t, svc.Events(), EventAuthDisconnected)

	mu.Lock()
	defer mu.Unlock()
	want := []State{StateConnected, StateDisconnected}
	if len(states) != len(want) || states[0] != want[0] || states[1] != want[1] {
		t.Fatalf("state callback got %v, want %v", states, want)
	}
}

func TestLoggedOutDeletesDeviceAndNeedsPairing(t *testing.T) {
	fake := newFakeClient()
	fake.loggedIn = true
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.LoggedOut{OnConnect: true, Reason: events.ConnectFailureLoggedOut})

	if !fake.wasDeleted() {
		t.Fatal("device was not deleted after LoggedOut")
	}
	if got := svc.State(); got != StateNeedsPairing {
		t.Fatalf("state = %q, want %q", got, StateNeedsPairing)
	}
	readEvent(t, svc.Events(), EventAuthDisconnected)
}

func TestConnectFailureLoggedOutDeletesDevice(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.ConnectFailure{Reason: events.ConnectFailureLoggedOut})

	if !fake.wasDeleted() {
		t.Fatal("device was not deleted after logged-out ConnectFailure")
	}
	if got := svc.State(); got != StateNeedsPairing {
		t.Fatalf("state = %q, want %q", got, StateNeedsPairing)
	}
}

func TestTemporaryBanSetsBanned(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.TemporaryBan{
		Code:   events.TempBanSentToTooManyPeople,
		Expire: time.Hour,
	})

	if got := svc.State(); got != StateBanned {
		t.Fatalf("state = %q, want %q", got, StateBanned)
	}
	st := svc.AuthStatus()
	if st.BanUntil.IsZero() || !st.BanUntil.After(time.Now()) {
		t.Fatalf("BanUntil = %v, want a future value", st.BanUntil)
	}
}

func TestStreamReplacedAndOutdated(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	svc.handleEvent(&events.StreamReplaced{})
	if got := svc.State(); got != StateStreamReplaced {
		t.Fatalf("state = %q, want %q", got, StateStreamReplaced)
	}
	// A later Disconnected must not downgrade a terminal state.
	svc.handleEvent(&events.Disconnected{})
	if got := svc.State(); got != StateStreamReplaced {
		t.Fatalf("terminal state was downgraded to %q", got)
	}

	svc2, _ := newTestService(t, newFakeClient())
	svc2.handleEvent(&events.ClientOutdated{})
	if got := svc2.State(); got != StateOutdated {
		t.Fatalf("state = %q, want %q", got, StateOutdated)
	}
}

func TestStartLoginEmitsQRWithoutLoggingCode(t *testing.T) {
	fake := newFakeClient()
	svc, logs := newTestService(t, fake)

	if err := svc.StartLogin(context.Background()); err != nil {
		t.Fatalf("StartLogin: %v", err)
	}
	if !fake.gotQRCodesBeforeConnect() {
		t.Fatal("GetQRChannel was not called before Connect")
	}

	const code = "2@SUPERSECRETQRCODE"
	fake.qrChan <- whatsmeow.QRChannelItem{
		Event:   whatsmeow.QRChannelEventCode,
		Code:    code,
		Timeout: 60 * time.Second,
	}

	ev := readEvent(t, svc.Events(), EventAuthQR)
	if ev.Data["code"] != code {
		t.Fatalf("auth.qr code = %v, want %q", ev.Data["code"], code)
	}
	if ev.Data["timeout"] != 60 {
		t.Fatalf("auth.qr timeout = %v, want 60", ev.Data["timeout"])
	}

	if strings.Contains(logs.String(), code) {
		t.Fatal("QR code leaked into the logs")
	}
	if !strings.Contains(logs.String(), "qr emitted") {
		t.Fatal("expected a redacted 'qr emitted' log line")
	}

	fake.qrChan <- whatsmeow.QRChannelItem{Event: "success"}
	readEvent(t, svc.Events(), EventAuthConnected)
	if got := svc.State(); got != StateConnected {
		t.Fatalf("after success: state = %q, want %q", got, StateConnected)
	}
}

func TestStartLoginAlreadyLoggedIn(t *testing.T) {
	t.Run("paired device", func(t *testing.T) {
		fake := newFakeClient()
		svc, _ := newTestService(t, fake)
		jid := types.NewJID("5511999999999", types.DefaultUserServer)
		setDevice(svc, &store.Device{ID: &jid})

		if err := svc.StartLogin(context.Background()); !errors.Is(err, ErrAlreadyLoggedIn) {
			t.Fatalf("StartLogin = %v, want ErrAlreadyLoggedIn", err)
		}
	})

	t.Run("client logged in", func(t *testing.T) {
		fake := newFakeClient()
		fake.loggedIn = true
		svc, _ := newTestService(t, fake)

		if err := svc.StartLogin(context.Background()); !errors.Is(err, ErrAlreadyLoggedIn) {
			t.Fatalf("StartLogin = %v, want ErrAlreadyLoggedIn", err)
		}
	})
}

func TestLogoutResetsToNeedsPairing(t *testing.T) {
	fake := newFakeClient()
	fake.loggedIn = true
	svc, _ := newTestService(t, fake)

	if err := svc.Logout(context.Background()); err != nil {
		t.Fatalf("Logout: %v", err)
	}
	if !fake.wasDeleted() {
		t.Fatal("device was not deleted on Logout")
	}
	if got := svc.State(); got != StateNeedsPairing {
		t.Fatalf("state = %q, want %q", got, StateNeedsPairing)
	}
}

func TestClassifyCoalescesPresenceButKeepsMessages(t *testing.T) {
	if ev := classify(&events.Presence{}); ev != nil {
		t.Fatalf("Presence should be coalesced, got %v", ev.kind)
	}
	if ev := classify(&events.ChatPresence{}); ev != nil {
		t.Fatalf("ChatPresence should be coalesced, got %v", ev.kind)
	}

	msg := &events.Message{Info: types.MessageInfo{
		MessageSource: types.MessageSource{
			Chat:   types.NewJID("5511999999999", types.DefaultUserServer),
			Sender: types.NewJID("5511888888888", types.DefaultUserServer),
		},
	}}
	ev := classify(msg)
	if ev == nil || ev.kind != evtMessage {
		t.Fatalf("Message classify = %v, want evtMessage", ev)
	}
	if ev.chatJID == "" || ev.senderJID == "" {
		t.Fatal("Message classification dropped the JIDs")
	}
}

func TestWALogAdapterRedactsJIDsAndDropsDebug(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	l := newWALogger(logger)

	l.Warnf("failed for %s", "5511999999999@s.whatsapp.net")
	l.Debugf("Emitting QR code %s", "SUPERSECRETQR")

	out := buf.String()
	if strings.Contains(out, "5511999999999") {
		t.Fatal("JID leaked through the whatsmeow log adapter")
	}
	if !strings.Contains(out, "***@s.whatsapp.net") {
		t.Fatalf("expected redacted JID, got: %s", out)
	}
	if strings.Contains(out, "SUPERSECRETQR") {
		t.Fatal("whatsmeow debug log (QR code) was forwarded")
	}
}

func TestConnectUnpairedFailsWithoutNetwork(t *testing.T) {
	fake := newFakeClient()
	svc, _ := newTestService(t, fake)

	if err := svc.Connect(context.Background()); !errors.Is(err, ErrNotPaired) {
		t.Fatalf("Connect = %v, want ErrNotPaired", err)
	}
}
