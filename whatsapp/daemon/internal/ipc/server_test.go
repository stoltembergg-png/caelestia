package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// newTestServer starts a Server on a socket inside t.TempDir() with a ping
// handler registered. The server is closed automatically at test cleanup.
func newTestServer(t *testing.T, opts ...Option) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "test.sock")

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(path, logger, opts...)
	srv.Register("ping", func(_ context.Context, _ *Client, _ json.RawMessage) (any, *Error) {
		return map[string]any{"pong": true}, nil
	})
	if err := srv.Start(); err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	t.Cleanup(func() {
		if err := srv.Close(); err != nil {
			t.Errorf("Close() error: %v", err)
		}
	})
	return srv, path
}

func dial(t *testing.T, path string) net.Conn {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial %q: %v", path, err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func sendLine(t *testing.T, conn net.Conn, line string) {
	t.Helper()
	if _, err := io.WriteString(conn, line+"\n"); err != nil {
		t.Fatalf("write request: %v", err)
	}
}

func readJSONLine(t *testing.T, r *bufio.Reader) map[string]json.RawMessage {
	t.Helper()
	line, err := r.ReadBytes('\n')
	if err != nil {
		t.Fatalf("read response line: %v", err)
	}
	var resp map[string]json.RawMessage
	if err := json.Unmarshal(line, &resp); err != nil {
		t.Fatalf("unmarshal response %q: %v", line, err)
	}
	return resp
}

func responseID(t *testing.T, resp map[string]json.RawMessage) uint64 {
	t.Helper()
	raw, ok := resp["id"]
	if !ok {
		t.Fatalf("response has no id: %v", resp)
	}
	var id uint64
	if err := json.Unmarshal(raw, &id); err != nil {
		t.Fatalf("unmarshal id %q: %v", raw, err)
	}
	return id
}

func errorCode(t *testing.T, resp map[string]json.RawMessage) string {
	t.Helper()
	raw, ok := resp["error"]
	if !ok {
		t.Fatalf("response has no error: %v", resp)
	}
	var e Error
	if err := json.Unmarshal(raw, &e); err != nil {
		t.Fatalf("unmarshal error %q: %v", raw, err)
	}
	return e.Code
}

func TestPingRoundTrip(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"id":1,"method":"ping"}`)
	resp := readJSONLine(t, r)

	if got := responseID(t, resp); got != 1 {
		t.Errorf("response id = %d, want 1", got)
	}
	if _, hasErr := resp["error"]; hasErr {
		t.Fatalf("unexpected error response: %v", resp)
	}
	var result struct {
		Pong bool `json:"pong"`
	}
	if err := json.Unmarshal(resp["result"], &result); err != nil {
		t.Fatalf("unmarshal result %q: %v", resp["result"], err)
	}
	if !result.Pong {
		t.Errorf("pong = false, want true")
	}
}

// TestHandlerReceivesRequestID verifies the server attaches the request id to
// the handler context so long-running methods can correlate progress events.
func TestHandlerReceivesRequestID(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "reqid.sock")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(path, logger)
	seen := make(chan uint64, 1)
	srv.Register("whoami", func(ctx context.Context, _ *Client, _ json.RawMessage) (any, *Error) {
		seen <- RequestIDFromContext(ctx)
		return map[string]any{"echo": RequestIDFromContext(ctx)}, nil
	})
	if err := srv.Start(); err != nil {
		t.Fatalf("Start() error: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	conn := dial(t, path)
	r := bufio.NewReader(conn)
	sendLine(t, conn, `{"id":42,"method":"whoami"}`)
	resp := readJSONLine(t, r)
	if got := responseID(t, resp); got != 42 {
		t.Fatalf("response id = %d, want 42", got)
	}
	select {
	case got := <-seen:
		if got != 42 {
			t.Fatalf("handler request id = %d, want 42", got)
		}
	case <-time.After(time.Second):
		t.Fatal("handler was not called")
	}
}

func TestMethodNotFound(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"id":7,"method":"does.not.exist"}`)
	resp := readJSONLine(t, r)

	if got := responseID(t, resp); got != 7 {
		t.Errorf("response id = %d, want 7", got)
	}
	if got := errorCode(t, resp); got != ErrorMethodNotFound {
		t.Errorf("error code = %q, want %q", got, ErrorMethodNotFound)
	}
}

func TestMalformedJSONReturnsParseError(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"id":1,"method":`)
	resp := readJSONLine(t, r)

	if got := errorCode(t, resp); got != ErrorParseError {
		t.Errorf("error code = %q, want %q", got, ErrorParseError)
	}
}

func TestMissingIDReturnsInvalidRequest(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"method":"ping"}`)
	resp := readJSONLine(t, r)

	if got := errorCode(t, resp); got != ErrorInvalidRequest {
		t.Errorf("error code = %q, want %q", got, ErrorInvalidRequest)
	}
}

func TestMethodTooLongReturnsInvalidRequest(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	method := strings.Repeat("m", MaxMethodLen+1)
	sendLine(t, conn, `{"id":2,"method":"`+method+`"}`)
	resp := readJSONLine(t, r)

	if got := errorCode(t, resp); got != ErrorInvalidRequest {
		t.Errorf("error code = %q, want %q", got, ErrorInvalidRequest)
	}
}

func TestParamsWrongTypeReturnsInvalidRequest(t *testing.T) {
	_, path := newTestServer(t)
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"id":3,"method":"ping","params":"nope"}`)
	resp := readJSONLine(t, r)

	if got := errorCode(t, resp); got != ErrorInvalidRequest {
		t.Errorf("error code = %q, want %q", got, ErrorInvalidRequest)
	}
}

func TestOversizedLineClosesConnection(t *testing.T) {
	_, path := newTestServer(t, WithMaxLineBytes(256))
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	if _, err := io.WriteString(conn, strings.Repeat("a", 4096)+"\n"); err != nil {
		t.Fatalf("write oversized line: %v", err)
	}

	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}

	// The server reports the framing error before dropping the connection.
	resp := readJSONLine(t, r)
	if got := errorCode(t, resp); got != ErrorParseError {
		t.Errorf("error code = %q, want %q", got, ErrorParseError)
	}

	// The connection must then be closed.
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("connection still open after oversized line")
	}
}

func TestBroadcastReachesAllClients(t *testing.T) {
	srv, path := newTestServer(t)

	conn1 := dial(t, path)
	conn2 := dial(t, path)
	r1 := bufio.NewReader(conn1)
	r2 := bufio.NewReader(conn2)

	// Round-trip a ping on each connection so the server has definitely
	// registered both clients before broadcasting.
	for _, conn := range []net.Conn{conn1, conn2} {
		sendLine(t, conn, `{"id":1,"method":"ping"}`)
	}
	readJSONLine(t, r1)
	readJSONLine(t, r2)

	srv.Broadcast("typing.updated", map[string]any{
		"chat":  "12345@s.whatsapp.net",
		"state": "composing",
	})

	for i, r := range []*bufio.Reader{r1, r2} {
		line, err := r.ReadBytes('\n')
		if err != nil {
			t.Fatalf("client %d: read event: %v", i+1, err)
		}
		var ev struct {
			Event string          `json:"event"`
			Data  json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("client %d: unmarshal event %q: %v", i+1, line, err)
		}
		if ev.Event != "typing.updated" {
			t.Errorf("client %d: event = %q, want %q", i+1, ev.Event, "typing.updated")
		}
		var data struct {
			State string `json:"state"`
		}
		if err := json.Unmarshal(ev.Data, &data); err != nil {
			t.Fatalf("client %d: unmarshal data %q: %v", i+1, ev.Data, err)
		}
		if data.State != "composing" {
			t.Errorf("client %d: state = %q, want %q", i+1, data.State, "composing")
		}
	}
}

func TestSocketPermissionIs0600(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("socket permission check is Linux-specific")
	}
	_, path := newTestServer(t)

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat(%q): %v", path, err)
	}
	if got := info.Mode().Perm(); got != socketPerm {
		t.Errorf("socket mode = %04o, want %04o", got, socketPerm)
	}
}

func TestCloseRemovesSocket(t *testing.T) {
	srv, path := newTestServer(t)

	if err := srv.Close(); err != nil {
		t.Fatalf("Close() error: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("socket still present after Close: stat err = %v", err)
	}
	if conn, err := net.Dial("unix", path); err == nil {
		_ = conn.Close()
		t.Fatal("dial succeeded after Close, want failure")
	}
}

func TestStartFailsWhenSocketDirMissing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "missing", "test.sock")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(path, logger)

	err := srv.Start()
	if err == nil {
		_ = srv.Close()
		t.Fatal("Start() succeeded with a missing socket directory, want error")
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("error = %v, want it to mention the missing directory", err)
	}
}

// TestSlowClientDoesNotBlockOthersOrShutdown wedges one connection (it asks for
// a payload larger than the socket buffer and never reads) and asserts the
// write deadline frees the writer: other clients keep working and Close returns
// promptly.
func TestSlowClientDoesNotBlockOthersOrShutdown(t *testing.T) {
	srv, path := newTestServer(t, WithWriteTimeout(200*time.Millisecond))
	srv.Register("big", func(_ context.Context, _ *Client, _ json.RawMessage) (any, *Error) {
		return map[string]any{"data": strings.Repeat("x", 4<<20)}, nil
	})

	slow := dial(t, path)
	fast := dial(t, path)
	rf := bufio.NewReader(fast)

	// Make sure the fast client is registered before wedging the slow one.
	sendLine(t, fast, `{"id":100,"method":"ping"}`)
	if id := responseID(t, readJSONLine(t, rf)); id != 100 {
		t.Fatalf("fast warmup id = %d, want 100", id)
	}

	// The slow client never reads its response.
	sendLine(t, slow, `{"id":1,"method":"big"}`)

	// Requests on the fast connection are handled on their own goroutine and
	// must not be stalled by the wedged peer.
	for i := 0; i < 3; i++ {
		sendLine(t, fast, `{"id":2,"method":"ping"}`)
		resp := readJSONLine(t, rf)
		if id := responseID(t, resp); id != 2 {
			t.Fatalf("fast ping %d id = %d, want 2", i, id)
		}
	}

	// Shutdown closes every client (unblocking the wedged write) and must not
	// wait for the write timeout to expire serially.
	done := make(chan error, 1)
	go func() { done <- srv.Close() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Close: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Close hung on a slow client")
	}
}

// TestDomainErrorDoesNotConsumeBudget asserts that a well-formed domain error
// is treated as a valid response for the consecutive-error budget.
func TestDomainErrorDoesNotConsumeBudget(t *testing.T) {
	srv, path := newTestServer(t, WithMaxConsecutiveErrors(2))
	srv.Register("domain.fail", func(_ context.Context, _ *Client, _ json.RawMessage) (any, *Error) {
		return nil, &Error{Code: "not_paired", Message: "no session"}
	})

	conn := dial(t, path)
	r := bufio.NewReader(conn)

	for i := 0; i < 6; i++ {
		sendLine(t, conn, `{"id":5,"method":"domain.fail"}`)
		resp := readJSONLine(t, r)
		if got := errorCode(t, resp); got != "not_paired" {
			t.Fatalf("iteration %d: code = %q, want not_paired", i, got)
		}
	}

	// The connection must survive far more domain errors than the budget.
	sendLine(t, conn, `{"id":9,"method":"ping"}`)
	if id := responseID(t, readJSONLine(t, r)); id != 9 {
		t.Fatalf("ping id = %d, want 9", id)
	}
}

// TestProtocolErrorConsumesBudget makes sure the budget still protects the
// server from malformed/flooding clients.
func TestProtocolErrorConsumesBudget(t *testing.T) {
	_, path := newTestServer(t, WithMaxConsecutiveErrors(2))
	conn := dial(t, path)
	r := bufio.NewReader(conn)

	sendLine(t, conn, `{"id":1`)
	if got := errorCode(t, readJSONLine(t, r)); got != ErrorParseError {
		t.Fatalf("first error = %q, want %q", got, ErrorParseError)
	}
	sendLine(t, conn, `{"id":2`)
	readJSONLine(t, r)

	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	if _, err := r.ReadBytes('\n'); err == nil {
		t.Fatal("connection still open after exhausting the protocol error budget")
	}
}

// TestBroadcastConcurrentWithClose exercises Broadcast racing with Close under
// the race detector: it must never panic and must not deadlock.
func TestBroadcastConcurrentWithClose(t *testing.T) {
	srv, path := newTestServer(t, WithWriteTimeout(200*time.Millisecond))
	conn := dial(t, path)

	// Drain the client so broadcasts are not constantly blocked on a full
	// socket buffer (the point is concurrency with Close, not backpressure).
	go func() {
		buf := make([]byte, 4096)
		for {
			if _, err := conn.Read(buf); err != nil {
				return
			}
		}
	}()

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				srv.Broadcast("test.event", map[string]any{"j": j})
			}
		}()
	}

	if err := srv.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	wg.Wait()
}

// TestCloseWithoutStartDoesNotRemovePath guards that Close only removes a
// socket it actually created.
func TestCloseWithoutStartDoesNotRemovePath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pre-existing")
	if err := os.WriteFile(path, []byte("keep me"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(path, logger)
	if err := srv.Close(); err != nil {
		t.Fatalf("Close before Start: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("Close before Start removed the path: %v", err)
	}
}

// TestMaxConnsRefusesExtraConnections checks the connection cap.
func TestMaxConnsRefusesExtraConnections(t *testing.T) {
	_, path := newTestServer(t, WithMaxConns(1))

	conn1 := dial(t, path)
	r1 := bufio.NewReader(conn1)
	sendLine(t, conn1, `{"id":1,"method":"ping"}`)
	readJSONLine(t, r1) // conn1 is accepted and counted before conn2 dials

	conn2, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial conn2: %v", err)
	}
	defer conn2.Close()

	if err := conn2.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	if _, err := bufio.NewReader(conn2).ReadByte(); err == nil {
		t.Fatal("over-cap connection was not closed")
	}
}
