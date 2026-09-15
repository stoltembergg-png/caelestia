package whatsapp

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

func TestAvatarsDownloadPersistsAndCaches(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("PNGDATA"))
	}))
	defer srv.Close()
	mf.avatarInfo = &types.ProfilePictureInfo{URL: srv.URL + "/pic.png", ID: "avatar-1"}

	got, ipcErr := m.AvatarsDownload(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net"}`))
	if ipcErr != nil {
		t.Fatalf("AvatarsDownload: %v", ipcErr)
	}
	res, ok := got.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v", got)
	}
	if res["id"] != "avatar-1" || res["cached"] != false {
		t.Fatalf("result = %#v", res)
	}
	path, _ := res["path"].(string)
	if path == "" || !fileExists(path) {
		t.Fatalf("path %q does not exist", path)
	}
	if !pathWithin(m.dataDir, path) {
		t.Fatalf("avatar path %q escapes data dir %q", path, m.dataDir)
	}
	if filepath.Base(path) == "" || filepath.Ext(path) != ".png" {
		t.Fatalf("avatar file name = %q, want <sha1>.png", filepath.Base(path))
	}
	if b, err := os.ReadFile(path); err != nil || string(b) != "PNGDATA" {
		t.Fatalf("avatar content = %q (%v)", b, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("avatar perm = %o, want 600", perm)
	}

	contact, err := repo.GetContact(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetContact: %v", err)
	}
	if contact.AvatarID != "avatar-1" || contact.AvatarPath != path {
		t.Fatalf("contact = %+v", contact)
	}

	// Second call is a cache hit and must not hit the network again.
	mf.avatarInfo = nil
	got2, ipcErr := m.AvatarsDownload(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net"}`))
	if ipcErr != nil {
		t.Fatalf("AvatarsDownload cached: %v", ipcErr)
	}
	res2 := got2.(map[string]any)
	if res2["cached"] != true || res2["path"] != path || res2["id"] != "avatar-1" {
		t.Fatalf("cached result = %#v", res2)
	}
}

func TestAvatarsDownloadErrors(t *testing.T) {
	m, _, mf, _, ctx := newTestMethods(t)

	if _, ipcErr := m.AvatarsDownload(ctx, json.RawMessage(`{}`)); ipcErr == nil || ipcErr.Code != CodeInvalidRequest {
		t.Fatalf("missing jid error = %v, want %s", ipcErr, CodeInvalidRequest)
	}
	if _, ipcErr := m.AvatarsDownload(ctx, json.RawMessage(`{"jid":"not a jid"}`)); ipcErr == nil || ipcErr.Code != CodeInvalidRequest {
		t.Fatalf("bad jid error = %v, want %s", ipcErr, CodeInvalidRequest)
	}

	mf.avatarErr = errors.New("profile picture not found")
	if _, ipcErr := m.AvatarsDownload(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net"}`)); ipcErr == nil || ipcErr.Code != CodeNotFound {
		t.Fatalf("not found error = %v, want %s", ipcErr, CodeNotFound)
	}
}

func TestAvatarBackfillReturnsStoredAndCachesNegative(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)
	const jid = "bob@s.whatsapp.net"

	// A stored avatar path wins immediately, without any network call.
	stored := filepath.Join(m.dataDir, "cache", "avatars", "stored.jpg")
	if err := os.MkdirAll(filepath.Dir(stored), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(stored, []byte("x"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := repo.UpsertContact(ctx, database.Contact{JID: jid, AvatarPath: stored, AvatarID: "id1"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}
	if got := m.avatars.backfill(ctx, jid); got != stored {
		t.Fatalf("backfill = %q, want %q", got, stored)
	}
	if n := mf.avatarCallCount(); n != 0 {
		t.Fatalf("avatar lookups = %d, want 0 for a stored path", n)
	}

	// An unknown JID triggers a background fetch; a failure is negatively
	// cached so a later read does not retry immediately.
	const other = "carol@s.whatsapp.net"
	mf.avatarErr = errors.New("boom")
	if got := m.avatars.backfill(ctx, other); got != "" {
		t.Fatalf("backfill miss = %q, want empty", got)
	}
	waitFor(t, 2*time.Second, func() bool {
		_, _, ok := m.avatars.lookup(other)
		return ok
	})
	if n := mf.avatarCallCount(); n != 1 {
		t.Fatalf("avatar lookups = %d, want 1", n)
	}
	if got := m.avatars.backfill(ctx, other); got != "" {
		t.Fatalf("negative backfill = %q, want empty", got)
	}
	if n := mf.avatarCallCount(); n != 1 {
		t.Fatalf("negative cache not honored: avatar lookups = %d, want 1", n)
	}
}
