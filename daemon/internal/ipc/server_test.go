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
