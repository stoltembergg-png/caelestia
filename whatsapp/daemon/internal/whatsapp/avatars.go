package whatsapp

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// Avatar cache tuning. A positive result is stable for a while; a negative one
// is retried sooner because a contact can set a picture at any moment. The map
// is bounded so a long-lived daemon cannot grow it without limit.
const (
	avatarPositiveTTL  = 10 * time.Minute
	avatarNegativeTTL  = 2 * time.Minute
	avatarFetchTimeout = 20 * time.Second
	avatarMaxBytes     = 8 << 20 // 8 MiB is plenty for a profile picture
	avatarCacheMax     = 4096
	avatarMaxInflight  = 4
)

// errAvatarNotFound means the peer has no profile picture (or hides it). It
// maps to the stable not_found code.
var errAvatarNotFound = errors.New("whatsapp: avatar not found")

type avatarCacheEntry struct {
	path    string
	id      string
	expires time.Time
}

// avatarStore is the lazy avatar backfill cache shared by the IPC methods. It
// keeps paths confined to <data-dir>/cache/avatars and never stores image bytes
// in memory beyond the HTTP copy buffer.
type avatarStore struct {
	repo   *database.Repo
	svc    *Service
	logger *slog.Logger
	dir    string
	client *http.Client

	mu    sync.Mutex
	cache map[string]avatarCacheEntry
	busy  map[string]bool
	sem   chan struct{}
}

func newAvatarStore(repo *database.Repo, svc *Service, logger *slog.Logger, dir string) *avatarStore {
	if logger == nil {
		logger = slog.Default()
	}
	return &avatarStore{
		repo:   repo,
		svc:    svc,
		logger: logger,
		dir:    dir,
		client: &http.Client{Timeout: avatarFetchTimeout},
		cache:  make(map[string]avatarCacheEntry),
		busy:   make(map[string]bool),
		sem:    make(chan struct{}, avatarMaxInflight),
	}
}

// lookup returns a still-valid cache entry. ok is false when there is none.
// A cached empty path is a recent negative result.
func (a *avatarStore) lookup(jid string) (path, id string, ok bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	e, found := a.cache[jid]
	if !found || time.Now().After(e.expires) {
		return "", "", false
	}
	// Defensive: only a path we built under the avatar dir is ever served.
	if e.path != "" && !pathWithin(a.dir, e.path) {
		return "", "", false
	}
	return e.path, e.id, true
}

// remember stores a result in the TTL cache, dropping it when the cache is full
// rather than growing without bound.
func (a *avatarStore) remember(jid, path, id string) {
	ttl := avatarPositiveTTL
	if path == "" {
		ttl = avatarNegativeTTL
	}
	a.mu.Lock()
	if len(a.cache) >= avatarCacheMax {
		a.mu.Unlock()
		return
	}
	a.cache[jid] = avatarCacheEntry{path: path, id: id, expires: time.Now().Add(ttl)}
	a.mu.Unlock()
}

// backfill returns the stored avatar path for jid (from the in-memory cache or
// cae_contacts) and, when unknown, schedules a background fetch. It never
// blocks on the network: a miss returns "" immediately and the caller emits
// chat.updated later, when the fetch finishes.
func (a *avatarStore) backfill(ctx context.Context, jid string) string {
	if path, _, ok := a.lookup(jid); ok {
		return path
	}
	if c, err := a.repo.GetContact(ctx, jid); err == nil && c.AvatarPath != "" &&
		fileExists(c.AvatarPath) && pathWithin(a.dir, c.AvatarPath) {
		a.remember(jid, c.AvatarPath, c.AvatarID)
		return c.AvatarPath
	}
	a.schedule(jid)
	return ""
}

// schedule launches a background fetch unless one is already running or the
// inflight limit is reached. The goroutine is tracked by the service so Close
// waits for it and the event channel is still valid when it emits.
func (a *avatarStore) schedule(jid string) {
	a.mu.Lock()
	if a.busy[jid] {
		a.mu.Unlock()
		return
	}
	select {
	case a.sem <- struct{}{}:
		a.busy[jid] = true
	default:
		// Too many avatar fetches in flight; try again on a later read.
		a.mu.Unlock()
		return
	}
	a.mu.Unlock()

	started := a.svc.goTracked(func() {
		defer func() {
			<-a.sem
			a.mu.Lock()
			delete(a.busy, jid)
			a.mu.Unlock()
		}()
		fctx, cancel := context.WithTimeout(a.svc.ctx, avatarFetchTimeout)
		defer cancel()
		parsed, err := types.ParseJID(jid)
		if err != nil {
			a.remember(jid, "", "")
			return
		}
		path, id, err := a.download(fctx, parsed)
		if err != nil {
			a.logger.Debug("whatsapp: avatar backfill failed",
				slog.String("jid", logging.RedactJID(jid)),
				slog.String("error", err.Error()))
			a.remember(jid, "", "")
			return
		}
		a.remember(jid, path, id)
		a.svc.emit(EventChatUpdated, map[string]any{"jid": jid, "avatar": path})
	})
	if !started {
		<-a.sem
		a.mu.Lock()
		delete(a.busy, jid)
		a.mu.Unlock()
	}
}

// download performs one synchronous avatar fetch: resolve the URL, stream the
// bytes to a 0600 file named <sha1>.<ext>, persist it on cae_contacts and
// return the absolute path. It is used by both the explicit avatars.download
// method and the lazy backfill.
func (a *avatarStore) download(ctx context.Context, jid types.JID) (path, id string, err error) {
	c := a.svc.fullClient()
	if c == nil {
		return "", "", ErrNotPaired
	}
	info, err := c.GetProfilePictureInfo(ctx, jid, &whatsmeow.GetProfilePictureParams{Preview: false})
	if err != nil {
		return "", "", fmt.Errorf("%w: %v", errAvatarNotFound, err)
	}
	if info == nil || info.URL == "" {
		return "", "", errAvatarNotFound
	}
	jidStr := jid.String()

	// Reuse a persisted picture whose ID still matches, so repeated downloads
	// do not re-fetch bytes.
	if contact, cerr := a.repo.GetContact(ctx, jidStr); cerr == nil &&
		contact.AvatarPath != "" && fileExists(contact.AvatarPath) && pathWithin(a.dir, contact.AvatarPath) &&
		(contact.AvatarID == "" || info.ID == "" || contact.AvatarID == info.ID) {
		return contact.AvatarPath, info.ID, nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, info.URL, nil)
	if err != nil {
		return "", "", err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", "", fmt.Errorf("%w: http %d", errAvatarNotFound, resp.StatusCode)
	}

	if err := os.MkdirAll(a.dir, database.DirPerm); err != nil {
		return "", "", err
	}
	tmp, err := os.CreateTemp(a.dir, ".avatar-*")
	if err != nil {
		return "", "", err
	}
	tmpPath := tmp.Name()
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	n, copyErr := io.Copy(tmp, io.LimitReader(resp.Body, avatarMaxBytes+1))
	if copyErr != nil {
		err = copyErr
		return "", "", err
	}
	if n > avatarMaxBytes {
		err = errors.New("whatsapp: avatar exceeds size limit")
		return "", "", err
	}
	if closeErr := tmp.Close(); closeErr != nil {
		err = closeErr
		return "", "", err
	}

	ext := avatarExtension(resp.Header.Get("Content-Type"), info.URL)
	key := info.ID
	if key == "" {
		key = info.URL
	}
	sum := sha1.Sum([]byte(key))
	final := filepath.Join(a.dir, hex.EncodeToString(sum[:])+"."+ext)
	if !pathWithin(a.dir, final) {
		err = errors.New("whatsapp: avatar path escapes cache dir")
		return "", "", err
	}
	if renameErr := os.Rename(tmpPath, final); renameErr != nil {
		err = renameErr
		return "", "", err
	}
	if chmodErr := os.Chmod(final, database.FilePerm); chmodErr != nil {
		err = chmodErr
		return "", "", err
	}

	if uerr := a.repo.UpsertContact(ctx, database.Contact{
		JID:        jidStr,
		AvatarID:   info.ID,
		AvatarPath: final,
	}); uerr != nil {
		// The file is on disk; a persist failure only costs a re-download.
		a.logger.Warn("whatsapp: persist avatar failed",
			slog.String("jid", logging.RedactJID(jidStr)),
			slog.String("error", uerr.Error()))
	}
	return final, info.ID, nil
}

// avatarExtension picks a safe extension from the response content type, then
// the URL path, defaulting to jpg.
func avatarExtension(contentType, rawURL string) string {
	ct := strings.ToLower(strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0]))
	switch ct {
	case "image/jpeg", "image/jpg":
		return "jpg"
	case "image/png":
		return "png"
	case "image/webp":
		return "webp"
	case "image/gif":
		return "gif"
	}
	if u, err := url.Parse(rawURL); err == nil {
		if ext := safeExtension(filepath.Ext(u.Path)); ext != "" {
			return ext
		}
	}
	return "jpg"
}

// fileExists reports whether path is a regular file.
func fileExists(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// pathWithin reports whether child is strictly inside root (or equal to it).
// Both paths are cleaned first.
func pathWithin(root, child string) bool {
	rel, err := filepath.Rel(filepath.Clean(root), filepath.Clean(child))
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// --- avatars.download ---

type avatarsDownloadParams struct {
	JID string `json:"jid"`
}

// AvatarsDownload downloads (or reuses) the profile picture of jid and returns
// its cache path. It is the explicit, synchronous counterpart of the lazy
// backfill done by chats.list/chat.open.
func (m *Methods) AvatarsDownload(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p avatarsDownloadParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.JID) == "" {
		return nil, invalidRequest("jid is required")
	}
	jid, err := parseJID(p.JID)
	if err != nil {
		return nil, invalidRequest("invalid jid: " + err.Error())
	}
	if path, id, ok := m.avatars.lookup(p.JID); ok && path != "" {
		return map[string]any{"path": path, "id": id, "cached": true}, nil
	}

	path, id, derr := m.avatars.download(ctx, jid)
	if derr != nil {
		return nil, avatarError(p.JID, derr)
	}
	m.avatars.remember(p.JID, path, id)
	m.svc.emit(EventChatUpdated, map[string]any{"jid": p.JID, "avatar": path})
	return map[string]any{"path": path, "id": id, "cached": false}, nil
}

// avatarError maps avatar failures to the stable protocol codes without leaking
// internals.
func avatarError(jid string, err error) *ipc.Error {
	switch {
	case errors.Is(err, ErrNotPaired):
		return &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	case errors.Is(err, errAvatarNotFound), errors.Is(err, database.ErrNotFound):
		return &ipc.Error{Code: CodeNotFound, Message: "whatsapp: avatar not found"}
	default:
		return &ipc.Error{Code: CodeDownloadFailed, Message: "whatsapp: avatar download failed"}
	}
}
