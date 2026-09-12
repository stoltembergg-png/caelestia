// Command cwctl is a thin command-line client for the caelestia-whatsappd
// Unix domain socket. It speaks the raw NDJSON protocol described in
// docs/IPC.md and deliberately does not import the daemon module.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	qrterminal "github.com/mdp/qrterminal/v3"
)

const (
	defaultSocketName = "caelestia-whatsapp.sock"
	requestTimeout    = 10 * time.Second
	maxLineBytes      = 1 << 20
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "cwctl:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	socket, rest := extractSocket(args)
	if len(rest) == 0 {
		usage()
		return errors.New("missing command")
	}

	cmd := rest[0]
	cmdArgs := rest[1:]

	switch cmd {
	case "help", "-h", "--help":
		usage()
		return nil
	case "status":
		return cmdStatus(socket)
	case "chats":
		return cmdChats(socket, cmdArgs)
	case "messages":
		return cmdMessages(socket, cmdArgs)
	case "send":
		return cmdSend(socket, cmdArgs)
	case "avatar":
		return cmdAvatar(socket, cmdArgs)
	case "media":
		return cmdMedia(socket, cmdArgs)
	case "login":
		return cmdLogin(socket, cmdArgs)
	case "logout":
		return cmdLogout(socket)
	default:
		usage()
		return fmt.Errorf("unknown command %q", cmd)
	}
}

// extractSocket pulls --socket out of args (either before or after the
// subcommand) so the remaining arguments can be parsed per subcommand.
func extractSocket(args []string) (string, []string) {
	socket := defaultSocketPath()
	rest := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--socket" || a == "-socket":
			if i+1 < len(args) {
				i++
				socket = args[i]
			}
		case strings.HasPrefix(a, "--socket="):
			socket = strings.TrimPrefix(a, "--socket=")
		default:
			rest = append(rest, a)
		}
	}
	return socket, rest
}

func defaultSocketPath() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = "/tmp"
	}
	return filepath.Join(dir, defaultSocketName)
}

func usage() {
	fmt.Fprint(os.Stderr, `cwctl — cliente do daemon caelestia-whatsappd

Uso:
  cwctl [--socket CAMINHO] <comando> [opções]

Comandos:
  status                     estado da conexão/autenticação
  chats [--limit N]          lista de conversas
  messages <jid> [--limit N] histórico recente de uma conversa
  send <jid> <texto>         envia uma mensagem de texto
  avatar <jid>               baixa o avatar e imprime o caminho
  media <jid> <id>           baixa a mídia de uma mensagem e imprime o caminho
  login [--timeout 2m]       pareia via QR (imprime o QR no terminal)
  logout                     desvincula o dispositivo

Opções globais:
  --socket CAMINHO   socket UDS (padrão: $XDG_RUNTIME_DIR/caelestia-whatsapp.sock)
`)
}

// --- subcommands ---

type authInfo struct {
	State    string `json:"state"`
	LoggedIn bool   `json:"logged_in"`
	JID      string `json:"jid"`
	PushName string `json:"push_name"`
}

type statusResult struct {
	Version    string `json:"version"`
	Socket     string `json:"socket"`
	Connection struct {
		State string `json:"state"`
	} `json:"connection"`
	Auth authInfo `json:"auth"`
}

func cmdStatus(socket string) error {
	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var res statusResult
	if err := c.Call("status", nil, requestTimeout, &res); err != nil {
		return err
	}

	state := res.Auth.State
	if state == "" {
		state = res.Connection.State
	}
	fmt.Printf("state:      %s\n", state)
	fmt.Printf("logged_in:  %t\n", res.Auth.LoggedIn)
	if res.Auth.JID != "" {
		fmt.Printf("jid:        %s\n", res.Auth.JID)
	}
	if res.Auth.PushName != "" {
		fmt.Printf("push_name:  %s\n", res.Auth.PushName)
	}
	if res.Version != "" {
		fmt.Printf("version:    %s\n", res.Version)
	}
	return nil
}

type chatInfo struct {
	JID         string `json:"jid"`
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	LastMessage string `json:"lastMessage"`
	Timestamp   string `json:"timestamp"`
	Unread      int    `json:"unread"`
}

func cmdChats(socket string, args []string) error {
	fs := flag.NewFlagSet("chats", flag.ContinueOnError)
	limit := fs.Int("limit", 50, "máximo de conversas")
	if err := fs.Parse(args); err != nil {
		return err
	}

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var chats []chatInfo
	if err := c.Call("chats.list", map[string]any{"limit": *limit}, requestTimeout, &chats); err != nil {
		return err
	}
	if len(chats) == 0 {
		fmt.Println("(nenhuma conversa)")
		return nil
	}
	for _, chat := range chats {
		fmt.Printf("%-38s %-30s unread=%-3d %s\n",
			chat.JID, truncate(chat.Name, 30), chat.Unread, truncate(chat.LastMessage, 40))
	}
	return nil
}

type messageInfo struct {
	ID        string `json:"id"`
	Chat      string `json:"chat"`
	Sender    string `json:"sender"`
	FromMe    bool   `json:"fromMe"`
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Text      string `json:"text"`
	Status    string `json:"status"`
	Media     *struct {
		Kind       string  `json:"kind"`
		Mime       string  `json:"mime"`
		Size       int64   `json:"size"`
		Width      int     `json:"width"`
		Height     int     `json:"height"`
		Downloaded bool    `json:"downloaded"`
		Thumb      *string `json:"thumb"`
	} `json:"media"`
}

func cmdMessages(socket string, args []string) error {
	fs := flag.NewFlagSet("messages", flag.ContinueOnError)
	limit := fs.Int("limit", 50, "máximo de mensagens")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) < 1 {
		return errors.New("usage: cwctl messages <jid> [--limit N]")
	}
	jid := rest[0]

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var msgs []messageInfo
	if err := c.Call("chat.messages", map[string]any{"jid": jid, "limit": *limit}, requestTimeout, &msgs); err != nil {
		return err
	}
	if len(msgs) == 0 {
		fmt.Println("(nenhuma mensagem)")
		return nil
	}
	// The daemon returns newest first; print oldest first for readability.
	for i := len(msgs) - 1; i >= 0; i-- {
		printMessage(msgs[i])
	}
	return nil
}

func printMessage(m messageInfo) {
	who := "them"
	if m.FromMe {
		who = "me  "
	}
	ts := formatTimestamp(m.Timestamp)
	text := m.Text
	if text == "" {
		text = "[" + m.Type + "]"
	}
	status := ""
	if m.Status != "" {
		status = " (" + m.Status + ")"
	}
	media := ""
	if m.Media != nil {
		media = " media=" + m.Media.Kind
		if m.Media.Downloaded {
			media += " downloaded"
		}
	}
	fmt.Printf("%s %s id=%s %s%s%s\n", ts, who, m.ID, text, status, media)
}

func cmdSend(socket string, args []string) error {
	if len(args) < 2 {
		return errors.New("usage: cwctl send <jid> <texto>")
	}
	jid := args[0]
	text := strings.Join(args[1:], " ")

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var res struct {
		ID        string `json:"id"`
		Timestamp string `json:"timestamp"`
	}
	if err := c.Call("message.send", map[string]any{"jid": jid, "text": text}, 30*time.Second, &res); err != nil {
		return err
	}
	fmt.Printf("sent id=%s timestamp=%s\n", res.ID, res.Timestamp)
	return nil
}

// cmdAvatar downloads (or reuses) a chat/contact avatar and prints its path.
func cmdAvatar(socket string, args []string) error {
	if len(args) < 1 {
		return errors.New("usage: cwctl avatar <jid>")
	}
	jid := args[0]

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var res struct {
		Path   string `json:"path"`
		ID     string `json:"id"`
		Cached bool   `json:"cached"`
	}
	if err := c.Call("avatars.download", map[string]any{"jid": jid}, 60*time.Second, &res); err != nil {
		return err
	}
	fmt.Printf("path=%s id=%s cached=%t\n", res.Path, res.ID, res.Cached)
	return nil
}

// cmdMedia downloads a message's media (streaming to the daemon cache) and
// prints the resulting paths/metadata. Bytes never travel over the socket.
func cmdMedia(socket string, args []string) error {
	if len(args) < 2 {
		return errors.New("usage: cwctl media <jid> <id>")
	}
	chat, id := args[0], args[1]

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var res struct {
		Kind   string  `json:"kind"`
		Mime   string  `json:"mime"`
		Size   int64   `json:"size"`
		Width  int     `json:"width"`
		Height int     `json:"height"`
		Path   string  `json:"path"`
		Thumb  *string `json:"thumb"`
		Cached bool    `json:"cached"`
	}
	if err := c.Call("media.download", map[string]any{"chat": chat, "id": id}, 3*time.Minute, &res); err != nil {
		return err
	}
	thumb := "-"
	if res.Thumb != nil {
		thumb = *res.Thumb
	}
	fmt.Printf("path=%s kind=%s mime=%s size=%d %dx%d thumb=%s cached=%t\n",
		res.Path, res.Kind, res.Mime, res.Size, res.Width, res.Height, thumb, res.Cached)
	return nil
}

func cmdLogout(socket string) error {
	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var res struct {
		LoggedOut bool   `json:"logged_out"`
		State     string `json:"state"`
	}
	if err := c.Call("auth.logout", nil, 30*time.Second, &res); err != nil {
		return err
	}
	fmt.Printf("logged_out=%t state=%s\n", res.LoggedOut, res.State)
	return nil
}

// cmdLogin starts the QR pairing flow, renders every QR code in the terminal
// and blocks until auth.connected or the timeout elapses.
func cmdLogin(socket string, args []string) error {
	fs := flag.NewFlagSet("login", flag.ContinueOnError)
	timeout := fs.Duration("timeout", 2*time.Minute, "tempo máximo aguardando o pareamento")
	if err := fs.Parse(args); err != nil {
		return err
	}

	c, err := dial(socket)
	if err != nil {
		return err
	}
	defer c.Close()

	var start struct {
		Started bool `json:"started"`
	}
	if err := c.Call("auth.start", nil, requestTimeout, &start); err != nil {
		return err
	}
	fmt.Println("Aguardando pareamento — escaneie o QR code abaixo no WhatsApp:")

	deadline := time.After(*timeout)
	for {
		select {
		case ev, ok := <-c.Events():
			if !ok {
				return errors.New("conexão encerrada antes do pareamento")
			}
			switch ev.Name {
			case "auth.qr":
				var data struct {
					Code    string `json:"code"`
					Timeout int    `json:"timeout"`
				}
				_ = json.Unmarshal(ev.Data, &data)
				if data.Code == "" {
					continue
				}
				fmt.Printf("\nQR (válido por ~%ds):\n", data.Timeout)
				qrterminal.GenerateHalfBlock(data.Code, qrterminal.L, os.Stdout)
			case "auth.connected":
				var data struct {
					JID      string `json:"jid"`
					PushName string `json:"push_name"`
				}
				_ = json.Unmarshal(ev.Data, &data)
				fmt.Println("\nConectado.")
				if data.JID != "" {
					fmt.Printf("jid:       %s\n", data.JID)
				}
				if data.PushName != "" {
					fmt.Printf("push_name: %s\n", data.PushName)
				}
				return nil
			case "auth.error":
				var data struct {
					Message string `json:"message"`
				}
				_ = json.Unmarshal(ev.Data, &data)
				fmt.Fprintf(os.Stderr, "aviso: %s\n", data.Message)
			}
		case <-deadline:
			return fmt.Errorf("tempo esgotado (%s) sem pareamento", *timeout)
		}
	}
}

// --- NDJSON client ---

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string {
	if e.Code == "" {
		return e.Message
	}
	return e.Code + ": " + e.Message
}

type response struct {
	result json.RawMessage
	err    *rpcError
}

// event is a server-pushed message (no id).
type event struct {
	Name string
	Data json.RawMessage
}

// client is a minimal NDJSON request/response + event stream client.
type client struct {
	conn    net.Conn
	writeMu sync.Mutex

	mu      sync.Mutex
	nextID  uint64
	pending map[uint64]chan response

	events  chan event
	closed  chan struct{}
	closeMu sync.Once
	readErr error
}

func dial(socket string) (*client, error) {
	if socket == "" {
		return nil, errors.New("empty socket path")
	}
	conn, err := net.DialTimeout("unix", socket, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("connect %s: %w", socket, err)
	}
	c := &client{
		conn:    conn,
		pending: make(map[uint64]chan response),
		events:  make(chan event, 64),
		closed:  make(chan struct{}),
	}
	go c.readLoop()
	return c, nil
}

func (c *client) Close() { c.shutdown() }

func (c *client) shutdown() {
	c.closeMu.Do(func() {
		close(c.closed)
		_ = c.conn.Close()
		c.mu.Lock()
		for id, ch := range c.pending {
			close(ch)
			delete(c.pending, id)
		}
		c.mu.Unlock()
	})
}

// Events returns the stream of server events.
func (c *client) Events() <-chan event { return c.events }

func (c *client) readLoop() {
	defer c.shutdown()

	scanner := bufio.NewScanner(c.conn)
	scanner.Buffer(make([]byte, 0, 64<<10), maxLineBytes)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var env struct {
			ID     *uint64         `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *rpcError       `json:"error"`
			Event  string          `json:"event"`
			Data   json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(line, &env); err != nil {
			continue // malformed line: the protocol layer would have rejected it
		}
		if env.Event != "" {
			select {
			case c.events <- event{Name: env.Event, Data: env.Data}:
			default:
			}
			continue
		}
		if env.ID == nil {
			continue
		}
		c.mu.Lock()
		ch := c.pending[*env.ID]
		delete(c.pending, *env.ID)
		c.mu.Unlock()
		if ch != nil {
			ch <- response{result: env.Result, err: env.Error}
		}
	}
	c.mu.Lock()
	c.readErr = scanner.Err()
	c.mu.Unlock()
}

// Call sends a request and waits for its response, honoring timeout. out may
// be nil; otherwise the result JSON is unmarshaled into it.
func (c *client) Call(method string, params any, timeout time.Duration, out any) error {
	c.mu.Lock()
	c.nextID++
	id := c.nextID
	ch := make(chan response, 1)
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()

	req := map[string]any{"id": id, "method": method}
	if params != nil {
		req["params"] = params
	}
	line, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	c.writeMu.Lock()
	_, err = c.conn.Write(append(line, '\n'))
	c.writeMu.Unlock()
	if err != nil {
		return fmt.Errorf("write request: %w", err)
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case resp, ok := <-ch:
		if !ok {
			return errors.New("connection closed")
		}
		if resp.err != nil {
			return resp.err
		}
		if out == nil || len(resp.result) == 0 {
			return nil
		}
		if err := json.Unmarshal(resp.result, out); err != nil {
			return fmt.Errorf("decode result: %w", err)
		}
		return nil
	case <-timer.C:
		return fmt.Errorf("request %q timed out after %s", method, timeout)
	case <-c.closed:
		return errors.New("connection closed")
	}
}

// formatTimestamp turns a millisecond timestamp string into a local time.
func formatTimestamp(s string) string {
	ms, err := strconv.ParseInt(s, 10, 64)
	if err != nil || ms <= 0 {
		return "---------- --:--"
	}
	return time.UnixMilli(ms).Format("2006-01-02 15:04")
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) <= n {
		return s
	}
	if n <= 1 {
		return s[:n]
	}
	return s[:n-1] + "…"
}
