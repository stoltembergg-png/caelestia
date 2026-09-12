// Package logging sets up structured logging with log/slog and provides
// helpers to keep sensitive data out of the logs.
//
// Security rule: never log whatsmeow keys, tokens, session material or raw
// credentials. Identifiers such as JIDs and phone numbers must be redacted
// when they are not strictly necessary.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"strings"
)

// Redacted is the placeholder used instead of any secret value.
const Redacted = "[REDACTED]"

// ParseLevel converts a textual log level into a slog.Level.
func ParseLevel(s string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return slog.LevelDebug, nil
	case "info", "":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return slog.LevelInfo, fmt.Errorf("logging: invalid log level %q", s)
	}
}

// New returns a text-handler logger writing to w at the given level.
func New(w io.Writer, level slog.Level) *slog.Logger {
	handler := slog.NewTextHandler(w, &slog.HandlerOptions{Level: level})
	return slog.New(handler)
}

// RedactJID removes the user part of a JID, keeping only the server part.
//
//	"5511999999999@s.whatsapp.net" -> "***@s.whatsapp.net"
//	"12345@lid"                    -> "***@lid"
//	"not-a-jid"                    -> "***"
func RedactJID(jid string) string {
	_, server, ok := strings.Cut(jid, "@")
	if !ok || server == "" {
		return "***"
	}
	return "***@" + server
}

// RedactPhone masks a phone number, preserving only the last two digits.
//
//	"+5511999999999" -> "*************99"
//	"123"            -> "***"
func RedactPhone(phone string) string {
	p := strings.TrimSpace(phone)
	if len(p) <= 4 {
		return "***"
	}
	return strings.Repeat("*", len(p)-2) + p[len(p)-2:]
}

// SensitiveKey reports whether a log attribute name refers to a value that
// must never be written to the logs (keys, tokens, secrets, sessions).
func SensitiveKey(key string) bool {
	k := strings.ToLower(key)
	for _, marker := range []string{
		"key", "token", "secret", "password", "passwd",
		"credential", "session", "auth", "seed", "noise",
		"private", "signature", "mac",
	} {
		if strings.Contains(k, marker) {
			return true
		}
	}
	return false
}

// RedactAttr replaces the value of a sensitive slog.Attr with a placeholder.
// Non-sensitive attributes are returned unchanged.
func RedactAttr(a slog.Attr) slog.Attr {
	if SensitiveKey(a.Key) {
		return slog.String(a.Key, Redacted)
	}
	return a
}
