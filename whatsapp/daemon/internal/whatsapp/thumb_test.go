package whatsapp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// imageMessage builds an ImageMessage with an embedded thumbnail and a known
// file SHA-256 (all zeros when sha is nil).
func imageMessage(thumb []byte, sha []byte) *waE2E.Message {
	if sha == nil {
		sha = make([]byte, 32)
	}
	return &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
		Mimetype:      proto.String("image/jpeg"),
		FileLength:    proto.Uint64(1234),
		Width:         proto.Uint32(64),
		Height:        proto.Uint32(48),
		FileSHA256:    sha,
		DirectPath:    proto.String("/v/t62/abc"),
		MediaKey:      make([]byte, 32),
		JPEGThumbnail: thumb,
	}}
}

// TestPersistExtractsEmbeddedThumbnail verifies the embedded thumbnail is
// written at persistence time even though the full media is not downloaded.
func TestPersistExtractsEmbeddedThumbnail(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const chat = "a@s.whatsapp.net"
	const id = "m1"
	thumb := []byte{0xff, 0xd8, 0xff, 0xd9, 0x01, 0x02, 0x03}

	ev := testMessage(id, chat, "bob@s.whatsapp.net", false, 1, "")
	ev.Message = imageMessage(thumb, nil)
	if err := p.persistMessage(ctx, ev); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	md, err := repo.GetMedia(ctx, id)
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.ThumbPath == "" || !fileExists(md.ThumbPath) {
		t.Fatalf("thumb_path = %q, want an existing file", md.ThumbPath)
	}
	if !pathWithin(p.thumbDir, md.ThumbPath) {
		t.Fatalf("thumb %q escapes %q", md.ThumbPath, p.thumbDir)
	}
	if filepath.Base(md.ThumbPath) != strings.Repeat("0", 64)+".jpg" {
		t.Fatalf("thumb file name = %q, want <sha256>.jpg", filepath.Base(md.ThumbPath))
	}
	info, err := os.Stat(md.ThumbPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("thumb perms: err=%v", err)
	}
	if b, err := os.ReadFile(md.ThumbPath); err != nil || string(b) != string(thumb) {
		t.Fatalf("thumb content = %x (%v)", b, err)
	}
	// The full media is not downloaded, only the preview exists.
	if md.Status == "done" || md.Path != "" {
		t.Fatalf("media should not be marked downloaded: %+v", md)
	}
	payload := mediaPayload(md)
	if payload["downloaded"] != false {
		t.Fatalf("downloaded = %v, want false", payload["downloaded"])
	}
	if payload["thumb"] != md.ThumbPath {
		t.Fatalf("thumb payload = %v, want %q", payload["thumb"], md.ThumbPath)
	}
}

// TestPersistWithoutEmbeddedThumbLeavesItEmpty verifies a media message with no
// embedded thumbnail does not create a bogus file/path.
func TestPersistWithoutEmbeddedThumbLeavesItEmpty(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const chat = "a@s.whatsapp.net"
	const id = "m1"

	ev := testMessage(id, chat, "bob@s.whatsapp.net", false, 1, "")
	ev.Message = imageMessage(nil, nil)
	if err := p.persistMessage(ctx, ev); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	md, err := repo.GetMedia(ctx, id)
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.ThumbPath != "" {
		t.Fatalf("thumb_path = %q, want empty", md.ThumbPath)
	}
	if payload := mediaPayload(md); payload["thumb"] != nil {
		t.Fatalf("thumb payload = %v, want nil", payload["thumb"])
	}
}

// TestThumbRepairerBackfillsPastMedia verifies the startup pass regenerates
// thumbnails for proto-bearing rows that have none.
func TestThumbRepairerBackfillsPastMedia(t *testing.T) {
	_, repo, ctx := newTestPersister(t)
	dir := t.TempDir()
	thumb := []byte{0xff, 0xd8, 0xff, 0xd9, 0xaa}
	const chat = "a@s.whatsapp.net"
	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	for _, id := range []string{"m1", "m2", "m3"} {
		if _, err := repo.InsertMessage(ctx, database.Message{ID: id, ChatJID: chat, Timestamp: 1, Type: "image"}); err != nil {
			t.Fatalf("InsertMessage %s: %v", id, err)
		}
	}

	withThumb, err := proto.Marshal(&waE2E.ImageMessage{
		Mimetype:      proto.String("image/jpeg"),
		FileSHA256:    make([]byte, 32),
		JPEGThumbnail: thumb,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := repo.UpsertMedia(ctx, database.Media{
		ID: "m1", MessageID: "m1", Kind: "image", Mime: "image/jpeg", Proto: withThumb,
	}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}
	// A row with no embedded thumbnail must be left untouched (and not counted).
	noThumb, err := proto.Marshal(&waE2E.ImageMessage{
		Mimetype:   proto.String("image/jpeg"),
		FileSHA256: make([]byte, 32),
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := repo.UpsertMedia(ctx, database.Media{
		ID: "m2", MessageID: "m2", Kind: "image", Mime: "image/jpeg", Proto: noThumb,
	}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}
	// A document row is never a thumbnail candidate.
	if err := repo.UpsertMedia(ctx, database.Media{
		ID: "m3", MessageID: "m3", Kind: "document", Mime: "application/pdf", Proto: withThumb,
	}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}

	tr := NewThumbRepairer(nil, repo, dir, nil)
	if n := tr.RunOnce(ctx); n != 1 {
		t.Fatalf("generated = %d, want 1", n)
	}
	md, err := repo.GetMedia(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.ThumbPath == "" || !fileExists(md.ThumbPath) || !pathWithin(dir, md.ThumbPath) {
		t.Fatalf("repaired thumb_path = %q", md.ThumbPath)
	}
	if md2, _ := repo.GetMedia(ctx, "m2"); md2.ThumbPath != "" {
		t.Fatalf("no-thumb row got a thumb_path: %q", md2.ThumbPath)
	}
	if md3, _ := repo.GetMedia(ctx, "m3"); md3.ThumbPath != "" {
		t.Fatalf("document row got a thumb_path: %q", md3.ThumbPath)
	}
	// A second pass has nothing left to do.
	if got := tr.RunOnce(ctx); got != 0 {
		t.Fatalf("second pass generated = %d, want 0", got)
	}
}

// TestChatMessagesIncludesThumbWithoutDownload verifies the IPC payload exposes
// the embedded thumbnail while downloaded stays false.
func TestChatMessagesIncludesThumbWithoutDownload(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{ID: "m1", ChatJID: chat, Timestamp: 2, Type: "image"}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	// Write a real thumbnail file and record its path, without downloading.
	thumbPath := filepath.Join(m.thumbDir, "abc.jpg")
	if err := os.MkdirAll(filepath.Dir(thumbPath), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(thumbPath, []byte("thumb"), 0o600); err != nil {
		t.Fatalf("write thumb: %v", err)
	}
	if err := repo.UpsertMedia(ctx, database.Media{
		ID: "m1", MessageID: "m1", Kind: "image", Mime: "image/jpeg", Size: 10, ThumbPath: thumbPath,
	}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}
	// A second image with no thumbnail at all.
	if _, err := repo.InsertMessage(ctx, database.Message{ID: "m2", ChatJID: chat, Timestamp: 1, Type: "image"}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	if err := repo.UpsertMedia(ctx, database.Media{ID: "m2", MessageID: "m2", Kind: "image", Mime: "image/jpeg"}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}

	got, ipcErr := m.ChatMessages(ctx, mustJSON(t, map[string]any{"jid": chat, "limit": 10}))
	if ipcErr != nil {
		t.Fatalf("ChatMessages: %v", ipcErr)
	}
	msgs, ok := got.([]map[string]any)
	if !ok || len(msgs) != 2 {
		t.Fatalf("result = %#v", got)
	}
	byID := map[string]map[string]any{}
	for _, msg := range msgs {
		media, _ := msg["media"].(map[string]any)
		byID[msg["id"].(string)] = media
	}
	if byID["m1"]["thumb"] != thumbPath || byID["m1"]["downloaded"] != false {
		t.Fatalf("m1 media = %#v, want thumb and downloaded=false", byID["m1"])
	}
	if byID["m2"]["thumb"] != nil {
		t.Fatalf("m2 thumb = %v, want nil", byID["m2"]["thumb"])
	}
}
