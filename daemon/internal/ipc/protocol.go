// Package ipc implements the daemon's Unix domain socket server and the
// newline-delimited JSON (NDJSON) protocol described in docs/IPC.md.
//
// The protocol is intentionally small and stable:
//
//	request:  {"id":<uint64>,"method":"<ns.verb>","params":<object|null>}
//	response: {"id":N,"result":…} | {"id":N,"error":{"code":"…","message":"…"}}
//	event:    {"event":"<ns.verb>","data":{…}}
//
// # 64-bit integers on the wire
//
// The frontend is QML/JavaScript, whose Number type is an IEEE-754 double and
// therefore only represents integers exactly up to 2^53-1. WhatsApp message
// identifiers and millisecond timestamps can exceed that range, so when they
// appear inside an event payload they MUST be encoded as decimal strings, not
// as JSON numbers. The frontend never needs to do arithmetic on them.
//
// The StringID/StringTimestamp helpers below perform that encoding so that
// producers do not have to remember the rule.
package ipc

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"unicode/utf8"
)

// Protocol error codes. These strings are part of the public contract and must
// stay stable: clients switch on them.
const (
	// ErrorParseError means the line was not valid JSON (or a field had an
	// incompatible JSON type). The id, when recoverable, is echoed back.
	ErrorParseError = "parse_error"
	// ErrorInvalidRequest means the JSON was valid but the request envelope was
	// wrong: missing id, missing/oversized method, or a params value that is
	// neither an object nor null.
	ErrorInvalidRequest = "invalid_request"
	// ErrorMethodNotFound means the requested method is not registered.
	ErrorMethodNotFound = "method_not_found"
	// ErrorInternal means the handler panicked or returned an unexpected error.
	ErrorInternal = "internal_error"
)

// Protocol limits.
const (
	// DefaultMaxLineBytes is the maximum size of a single NDJSON line accepted
	// by the server. Media is never sent inline, only referenced by path, so
	// 1 MiB is plenty for control traffic.
	DefaultMaxLineBytes = 1 << 20 // 1 MiB

	// MaxMethodLen is the maximum length of a method name, in characters.
	MaxMethodLen = 64
)

// Request is a decoded client request.
type Request struct {
	ID     uint64
	Method string
	// Params is the raw params value. It is nil when the field is absent; the
	// raw bytes are passed to the handler untouched so each method can decode
	// its own typed payload.
	Params json.RawMessage
}

// Error is the protocol-level error object carried in a response.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Error implements the error interface so handlers can return *Error directly.
func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	return e.Code + ": " + e.Message
}

// Response is a reply to a Request. Exactly one of Result or Err is set; the
// custom MarshalJSON enforces the two documented shapes.
type Response struct {
	ID     uint64
	Result any
	Err    *Error
}

// MarshalJSON renders either {"id":N,"result":…} or {"id":N,"error":{…}}. On
// success the result field is always present (possibly null).
func (r Response) MarshalJSON() ([]byte, error) {
	if r.Err != nil {
		return json.Marshal(struct {
			ID    uint64 `json:"id"`
			Error *Error `json:"error"`
		}{ID: r.ID, Error: r.Err})
	}
	return json.Marshal(struct {
		ID     uint64 `json:"id"`
		Result any    `json:"result"`
	}{ID: r.ID, Result: r.Result})
}

// Event is a server-initiated notification broadcast to every connected
// client. It has no id: events are not replies and must not be matched against
// pending requests on the client side.
type Event struct {
	Event string `json:"event"`
	Data  any    `json:"data"`
}

// DecodeRequest parses one NDJSON line into a Request, enforcing the envelope
// limits. It never panics: malformed input yields a protocol *Error.
//
// Errors are classified as:
//   - ErrorParseError: the line is not valid JSON, or id/method have the wrong
//     JSON type.
//   - ErrorInvalidRequest: valid JSON, but id is absent, method is absent/empty
//     or longer than MaxMethodLen characters, or params is neither an object
//     nor null.
func DecodeRequest(line []byte) (*Request, *Error) {
	var wire struct {
		ID     *uint64         `json:"id"`
		Method *string         `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(line, &wire); err != nil {
		return nil, &Error{Code: ErrorParseError, Message: "invalid JSON: " + err.Error()}
	}

	if wire.ID == nil {
		return nil, &Error{Code: ErrorInvalidRequest, Message: "missing required field: id"}
	}
	if wire.Method == nil || *wire.Method == "" {
		return nil, &Error{Code: ErrorInvalidRequest, Message: "missing required field: method"}
	}
	if n := utf8.RuneCountInString(*wire.Method); n > MaxMethodLen {
		return nil, &Error{
			Code:    ErrorInvalidRequest,
			Message: fmt.Sprintf("method exceeds %d characters", MaxMethodLen),
		}
	}
	if len(wire.Params) > 0 {
		trimmed := bytes.TrimSpace(wire.Params)
		if len(trimmed) > 0 && trimmed[0] != '{' && !bytes.Equal(trimmed, []byte("null")) {
			return nil, &Error{Code: ErrorInvalidRequest, Message: "params must be an object or null"}
		}
	}

	return &Request{ID: *wire.ID, Method: *wire.Method, Params: wire.Params}, nil
}

// EncodeResponse marshals a success response (without the trailing newline).
func EncodeResponse(id uint64, result any) ([]byte, error) {
	return json.Marshal(Response{ID: id, Result: result})
}

// EncodeErrorResponse marshals an error response (without the trailing newline).
func EncodeErrorResponse(id uint64, e *Error) ([]byte, error) {
	if e == nil {
		e = &Error{Code: ErrorInternal, Message: "unspecified error"}
	}
	return json.Marshal(Response{ID: id, Err: e})
}

// EncodeEvent marshals an event envelope (without the trailing newline). Any
// 64-bit identifier inside data must already be a string; use StringID.
func EncodeEvent(event string, data any) ([]byte, error) {
	return json.Marshal(Event{Event: event, Data: data})
}

// StringID encodes a 64-bit unsigned identifier as a decimal string so that it
// survives the trip through JavaScript's 53-bit integer range.
func StringID(id uint64) string {
	return strconv.FormatUint(id, 10)
}

// StringTimestamp encodes a 64-bit signed timestamp (e.g. Unix milliseconds)
// as a decimal string for the same reason as StringID.
func StringTimestamp(ts int64) string {
	return strconv.FormatInt(ts, 10)
}

// requestIDKey is the private context key carrying the request id.
type requestIDKey struct{}

// WithRequestID returns a context carrying the id of the request being
// handled. The server attaches it before invoking a handler so a long-running
// method (e.g. media.send) can correlate progress events with the request.
func WithRequestID(ctx context.Context, id uint64) context.Context {
	return context.WithValue(ctx, requestIDKey{}, id)
}

// RequestIDFromContext returns the request id attached by WithRequestID, or 0
// when none is present.
func RequestIDFromContext(ctx context.Context) uint64 {
	id, _ := ctx.Value(requestIDKey{}).(uint64)
	return id
}
