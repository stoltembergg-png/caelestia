package ipc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const (
	// socketPerm restricts the Unix domain socket to its owner.
	socketPerm = os.FileMode(0o600)

	// defaultReadBuffer is the initial Scanner buffer size; it grows on demand
	// up to the configured maximum line size.
	defaultReadBuffer = 64 << 10

	// defaultMaxConsecutiveErrors is how many protocol errors in a row a client
	// may produce before the server drops its connection. It is a safety valve
	// against a stuck/abusive peer and can be tuned with
	// WithMaxConsecutiveErrors.
	defaultMaxConsecutiveErrors = 16

	// defaultWriteTimeout bounds a single response/event write so a client that
	// stops reading can never wedge a connection forever. On expiry the client
	// is closed (a partial line is never left on the wire). It can be tuned
	// with WithWriteTimeout.
	defaultWriteTimeout = 5 * time.Second
)

// Handler processes one request and returns either a result (marshaled as the
// response "result") or a protocol *Error. The returned value must be JSON
// marshalable. Handlers run in the connection's goroutine and must not block
// indefinitely.
type Handler func(ctx context.Context, c *Client, params json.RawMessage) (any, *Error)

// Option customizes a Server at construction time.
type Option func(*Server)

// WithMaxLineBytes sets the maximum accepted NDJSON line size, in bytes.
// Non-positive values are ignored.
func WithMaxLineBytes(n int) Option {
	return func(s *Server) {
		if n > 0 {
			s.maxLineBytes = n
		}
	}
}

// WithMaxConsecutiveErrors sets how many consecutive error responses a client
// may trigger before being disconnected. Zero disables the limit.
func WithMaxConsecutiveErrors(n int) Option {
	return func(s *Server) {
		if n >= 0 {
			s.maxConsecutiveErrors = n
		}
	}
}

// WithWriteTimeout bounds a single write to a client. A client that stops
// reading is then closed instead of blocking the writer forever. Non-positive
// values are ignored (the default of 5s is kept). Only useful for tests and
// unusual deployments, hence not part of the documented contract.
func WithWriteTimeout(d time.Duration) Option {
	return func(s *Server) {
		if d > 0 {
			s.writeTimeout = d
		}
	}
}

// WithMaxConns caps the number of simultaneous client connections. New
// connections above the cap are accepted and immediately closed with a log
// line. Non-positive values disable the cap (the default).
func WithMaxConns(n int) Option {
	return func(s *Server) {
		if n >= 0 {
			s.maxConns = n
		}
	}
}

// WithReadIdleTimeout closes a connection that sends no request line for d.
// Zero (the default) disables the idle deadline, which matters for clients
// (e.g. `cwctl login`) that intentionally stay connected without sending new
// requests while they wait for events.
func WithReadIdleTimeout(d time.Duration) Option {
	return func(s *Server) {
		if d >= 0 {
			s.readIdleTimeout = d
		}
	}
}

// Server is a Unix domain socket JSON-RPC server. It accepts one connection per
// client, dispatches request lines to registered handlers and can push events
// to every connected client with Broadcast.
//
// The peer UID is verified via SO_PEERCRED (Linux) and connections from another
// UID are refused. The socket file is created with mode 0600.
type Server struct {
	path                 string
	logger               *slog.Logger
	maxLineBytes         int
	maxConsecutiveErrors int
	maxConns             int
	writeTimeout         time.Duration
	readIdleTimeout      time.Duration
	peerUID              uint32
	ctx                  context.Context
	cancel               context.CancelFunc
	done                 chan struct{}
	startOne             sync.Once
	startErr             error
	closeOne             sync.Once

	mu       sync.RWMutex
	handlers map[string]Handler
	clients  map[*Client]struct{}

	listener net.Listener
	// bound records whether this server successfully created its socket, so
	// Close only removes a path it actually owns.
	bound     bool
	connCount atomic.Int64
	wg        sync.WaitGroup
}

// NewServer creates a Server bound to path. It does not touch the filesystem;
// call Start to create the socket and begin accepting connections.
func NewServer(path string, logger *slog.Logger, opts ...Option) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Server{
		path:                 path,
		logger:               logger,
		maxLineBytes:         DefaultMaxLineBytes,
		maxConsecutiveErrors: defaultMaxConsecutiveErrors,
		writeTimeout:         defaultWriteTimeout,
		peerUID:              uint32(os.Getuid()),
		ctx:                  ctx,
		cancel:               cancel,
		done:                 make(chan struct{}),
		handlers:             make(map[string]Handler),
		clients:              make(map[*Client]struct{}),
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Register installs the handler for method. Registering the same method twice
// replaces the previous handler. It is safe to call before Start only.
func (s *Server) Register(method string, h Handler) {
	s.mu.Lock()
	s.handlers[method] = h
	s.mu.Unlock()
}

// Start creates the socket and starts accepting connections in the background.
// It fails with a clear error if the socket directory does not exist, if the
// path is occupied by a non-socket file, or if the bind/chmod fails. Start is
// idempotent and safe to call more than once.
func (s *Server) Start() error {
	s.startOne.Do(func() {
		s.startErr = s.start()
	})
	return s.startErr
}

func (s *Server) start() error {
	if s.path == "" {
		return errors.New("ipc: empty socket path")
	}

	dir := filepath.Dir(s.path)
	if dir != "" && dir != "." {
		info, err := os.Stat(dir)
		if err != nil {
			return fmt.Errorf("ipc: socket directory %q does not exist: %w", dir, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("ipc: socket directory %q is not a directory", dir)
		}
	}

	if err := removeStaleSocket(s.path); err != nil {
		return err
	}

	ln, err := net.Listen("unix", s.path)
	if err != nil {
		return fmt.Errorf("ipc: listen on %q: %w", s.path, err)
	}
	// net.Listen creates the socket respecting the umask; force 0600.
	if err := os.Chmod(s.path, socketPerm); err != nil {
		_ = ln.Close()
		_ = os.Remove(s.path)
		return fmt.Errorf("ipc: chmod socket %q: %w", s.path, err)
	}

	s.listener = ln
	s.bound = true
	s.wg.Add(1)
	go s.acceptLoop()
	return nil
}

// acceptLoop accepts connections until the listener is closed. A failed Accept
// never terminates the server; it is logged and retried.
func (s *Server) acceptLoop() {
	defer s.wg.Done()
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.done:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			s.logger.Warn("ipc: accept failed", slog.String("error", err.Error()))
			continue
		}
		count := s.connCount.Add(1)
		if s.maxConns > 0 && count > int64(s.maxConns) {
			s.connCount.Add(-1)
			s.logger.Warn("ipc: refusing connection: max connections reached",
				slog.Int("max_conns", s.maxConns))
			_ = conn.Close()
			continue
		}
		s.wg.Add(1)
		go s.handleConn(conn)
	}
}

// handleConn verifies the peer UID, registers the client and reads NDJSON
// lines until the connection ends or the error budget is exhausted.
func (s *Server) handleConn(conn net.Conn) {
	defer s.wg.Done()
	defer conn.Close()
	defer s.connCount.Add(-1)

	uid, err := peerUID(conn)
	if err != nil {
		s.logger.Warn("ipc: rejecting connection: cannot verify peer uid",
			slog.String("error", err.Error()))
		return
	}
	if uid != s.peerUID {
		s.logger.Warn("ipc: rejecting connection from another uid",
			slog.Uint64("uid", uint64(uid)),
			slog.Uint64("expected_uid", uint64(s.peerUID)))
		return
	}

	c := &Client{
		conn:         conn,
		logger:       s.logger,
		writeTimeout: s.writeTimeout,
		maxErrors:    s.maxConsecutiveErrors,
	}
	s.addClient(c)
	defer s.removeClient(c)

	// A connection may be accepted right as Close is iterating the client set.
	// If Close ran before this client was registered it did not close us, so
	// check for shutdown before blocking on a read.
	select {
	case <-s.done:
		return
	default:
	}

	scanner := bufio.NewScanner(conn)
	initial := s.maxLineBytes
	if initial > defaultReadBuffer {
		initial = defaultReadBuffer
	}
	scanner.Buffer(make([]byte, 0, initial), s.maxLineBytes)

	for {
		if s.readIdleTimeout > 0 {
			_ = conn.SetReadDeadline(time.Now().Add(s.readIdleTimeout))
		}
		if !scanner.Scan() {
			break
		}
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if !s.dispatch(c, line) {
			return // error budget exhausted; noteError closed the connection
		}
	}

	if err := scanner.Err(); err != nil {
		switch {
		case errors.Is(err, bufio.ErrTooLong):
			c.writeError(0, &Error{
				Code:    ErrorParseError,
				Message: fmt.Sprintf("line exceeds maximum size of %d bytes", s.maxLineBytes),
			})
			s.logger.Warn("ipc: closing connection: line too long",
				slog.Int("max_line_bytes", s.maxLineBytes))
		case errors.Is(err, net.ErrClosed):
			// Connection was closed locally (shutdown or error budget).
		default:
			s.logger.Debug("ipc: connection read ended", slog.String("error", err.Error()))
		}
	}
}

// dispatch decodes and executes one line. It returns false when the client
// must be disconnected.
func (s *Server) dispatch(c *Client, line []byte) bool {
	req, perr := DecodeRequest(line)
	if perr != nil {
		c.writeError(requestIDOrZero(line), perr)
		return c.noteError()
	}

	s.mu.RLock()
	h := s.handlers[req.Method]
	s.mu.RUnlock()
	if h == nil {
		c.writeError(req.ID, &Error{
			Code:    ErrorMethodNotFound,
			Message: "unknown method: " + req.Method,
		})
		return c.noteError()
	}

	out := s.invoke(c, h, req)
	if out.err != nil {
		// A well-formed domain error (not_paired, not_found, send_failed, …)
		// is a valid handler outcome: it is reported to the client but must
		// NOT consume the consecutive-error budget, otherwise a client asking
		// for an unpaired resource a few times would be disconnected. Only a
		// handler panic counts as a protocol-level error.
		c.writeError(req.ID, out.err)
		if out.panicked {
			return c.noteError()
		}
		c.noteSuccess()
		return true
	}
	resp, err := EncodeResponse(req.ID, out.value)
	if err != nil {
		s.logger.Error("ipc: encode response",
			slog.String("method", req.Method),
			slog.String("error", err.Error()))
		c.writeError(req.ID, &Error{Code: ErrorInternal, Message: "failed to encode result"})
		return c.noteError()
	}
	c.noteSuccess()
	_ = c.writeLine(resp)
	return true
}

// invokeResult is the outcome of a handler call.
type invokeResult struct {
	value    any
	err      *Error
	panicked bool
}

// invoke runs a handler and converts a panic into an internal_error response
// so that a single bad handler cannot take down the server. The panicked flag
// lets dispatch distinguish a bug (error budget) from a normal domain error.
func (s *Server) invoke(c *Client, h Handler, req *Request) (out invokeResult) {
	defer func() {
		if r := recover(); r != nil {
			s.logger.Error("ipc: handler panic",
				slog.String("method", req.Method),
				slog.Any("panic", r))
			out = invokeResult{err: &Error{Code: ErrorInternal, Message: "internal error"}, panicked: true}
		}
	}()
	value, err := h(WithRequestID(s.ctx, req.ID), c, req.Params)
	if err != nil {
		return invokeResult{err: err}
	}
	return invokeResult{value: value}
}

// Broadcast sends an event to every connected client. Encoding or per-client
// write failures are logged and do not interrupt the loop. Any 64-bit
// identifier inside data must be a string; use StringID/StringTimestamp.
func (s *Server) Broadcast(event string, data any) {
	line, err := EncodeEvent(event, data)
	if err != nil {
		s.logger.Error("ipc: encode event",
			slog.String("event", event),
			slog.String("error", err.Error()))
		return
	}

	s.mu.RLock()
	clients := make([]*Client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.RUnlock()

	for _, c := range clients {
		if err := c.writeLine(line); err != nil {
			s.logger.Debug("ipc: broadcast write failed",
				slog.String("event", event),
				slog.String("error", err.Error()))
		}
	}
}

// Close stops accepting connections, closes every client, waits for the
// goroutines to finish and removes the socket file. It is safe to call more
// than once and to call before Start.
func (s *Server) Close() error {
	var err error
	s.closeOne.Do(func() {
		close(s.done)
		s.cancel()

		if s.listener != nil {
			if cerr := s.listener.Close(); cerr != nil && !errors.Is(cerr, net.ErrClosed) {
				err = fmt.Errorf("ipc: close listener: %w", cerr)
			}
		}

		s.mu.Lock()
		for c := range s.clients {
			c.close()
		}
		s.mu.Unlock()

		s.wg.Wait()

		// Only remove a path this server actually created; Close before a
		// successful Start must never touch the filesystem.
		if s.bound {
			if rerr := os.Remove(s.path); rerr != nil && !os.IsNotExist(rerr) {
				if err == nil {
					err = fmt.Errorf("ipc: remove socket %q: %w", s.path, rerr)
				}
			}
		}
	})
	return err
}

func (s *Server) addClient(c *Client) {
	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
}

func (s *Server) removeClient(c *Client) {
	s.mu.Lock()
	delete(s.clients, c)
	s.mu.Unlock()
}

// Client is one accepted IPC connection. Writes are serialized so that a
// handler response and a concurrent Broadcast cannot interleave on the wire.
type Client struct {
	conn         net.Conn
	logger       *slog.Logger
	writeMu      sync.Mutex
	writeTimeout time.Duration
	maxErrors    int
	errs         int
	closed       atomic.Bool
}

// writeLine writes one marshaled JSON line, serialized per client. A write
// deadline bounds a client that stops reading; on failure the connection is
// closed so a partially written line can never be followed by another frame.
func (c *Client) writeLine(line []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed.Load() {
		return net.ErrClosed
	}
	buf := make([]byte, 0, len(line)+1)
	buf = append(buf, line...)
	buf = append(buf, '\n')
	if err := c.conn.SetWriteDeadline(time.Now().Add(c.writeTimeout)); err != nil {
		c.close()
		return err
	}
	_, err := c.conn.Write(buf)
	if err != nil {
		c.close()
		return err
	}
	// Clear the deadline so a later write (e.g. a broadcast) gets its own.
	_ = c.conn.SetWriteDeadline(time.Time{})
	return nil
}

// writeError sends an error response, ignoring transport failures.
func (c *Client) writeError(id uint64, e *Error) {
	line, err := EncodeErrorResponse(id, e)
	if err != nil {
		c.logger.Error("ipc: encode error response", slog.String("error", err.Error()))
		return
	}
	_ = c.writeLine(line)
}

// noteError records a protocol error and reports whether the connection may
// stay open. It closes the connection when the budget is exhausted.
func (c *Client) noteError() bool {
	c.errs++
	if c.maxErrors > 0 && c.errs >= c.maxErrors {
		c.logger.Warn("ipc: closing client after consecutive protocol errors",
			slog.Int("count", c.errs))
		c.close()
		return false
	}
	return true
}

// noteSuccess resets the consecutive error budget.
func (c *Client) noteSuccess() { c.errs = 0 }

func (c *Client) close() {
	if c.closed.CompareAndSwap(false, true) {
		_ = c.conn.Close()
	}
}

// requestIDOrZero best-effort recovers the request id from a line that failed
// to decode, so error responses can still be correlated when possible.
func requestIDOrZero(line []byte) uint64 {
	var probe struct {
		ID *uint64 `json:"id"`
	}
	if err := json.Unmarshal(line, &probe); err == nil && probe.ID != nil {
		return *probe.ID
	}
	return 0
}

// removeStaleSocket removes a leftover socket file from a previous run. It
// refuses to delete a path that is not a socket.
func removeStaleSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("ipc: stat socket %q: %w", path, err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("ipc: refusing to remove %q: not a socket", path)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("ipc: remove stale socket %q: %w", path, err)
	}
	return nil
}

// peerUID returns the UID of the process on the other end of a Unix domain
// connection using SO_PEERCRED. This is a Linux-specific facility; any failure
// to obtain the credentials is reported as an error and the caller refuses the
// connection.
func peerUID(conn net.Conn) (uint32, error) {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, errors.New("not a unix domain connection")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return 0, err
	}
	var (
		cred    *unix.Ucred
		credErr error
	)
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return 0, err
	}
	if credErr != nil {
		return 0, credErr
	}
	return cred.Uid, nil
}
