// Package config loads the daemon configuration from command-line flags,
// falling back to XDG environment variables for the default paths.
package config

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const (
	// AppDirName is the directory name used under the XDG data directory.
	AppDirName = "caelestia-whatsapp"

	// SocketName is the default Unix domain socket file name.
	SocketName = "caelestia-whatsapp.sock"

	// DefaultLogLevel is used when --log-level is not provided.
	DefaultLogLevel = "info"
)

// Config holds the resolved runtime configuration of the daemon.
type Config struct {
	// DataDir is where the SQLite database and cache live.
	DataDir string
	// Socket is the path of the Unix domain socket (unused until the IPC step).
	Socket string
	// LogLevel is one of debug, info, warn or error.
	LogLevel string
}

// DefaultDataDir returns ${XDG_DATA_HOME:-~/.local/share}/caelestia-whatsapp.
func DefaultDataDir() string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil || home == "" {
			// Last resort: keep paths relative instead of failing to boot.
			home = "."
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, AppDirName)
}

// DefaultSocketPath returns ${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock.
func DefaultSocketPath() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = "/tmp"
	}
	return filepath.Join(dir, SocketName)
}

// Load parses args (without the program name) into a Config.
//
// Flags take precedence; the XDG environment variables only influence the
// default values. Errors from flag parsing are returned to the caller.
func Load(args []string) (*Config, error) {
	fs := flag.NewFlagSet("caelestia-whatsappd", flag.ContinueOnError)

	cfg := &Config{}
	fs.StringVar(&cfg.DataDir, "data-dir", DefaultDataDir(),
		"directory for the database and cache")
	fs.StringVar(&cfg.Socket, "socket", DefaultSocketPath(),
		"path to the Unix domain socket")
	fs.StringVar(&cfg.LogLevel, "log-level", DefaultLogLevel,
		"log level: debug, info, warn or error")

	if err := fs.Parse(args); err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

func (c *Config) validate() error {
	if c.DataDir == "" {
		return fmt.Errorf("config: data-dir must not be empty")
	}
	if c.Socket == "" {
		return fmt.Errorf("config: socket must not be empty")
	}
	if c.LogLevel == "" {
		return fmt.Errorf("config: log-level must not be empty")
	}
	return nil
}
