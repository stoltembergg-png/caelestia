package whatsapp

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// insertMediaMessage creates the chat, the message and its cae_media row for a
// test image. It returns the marshaled image proto.
func insertMediaMessage(t *testing.T, repo *database.Repo, ctx context.Context, id, chat string, im *waE2E.ImageMessage) []byte {
	t.Helper()
	if err := repo.UpsertChat(ctx, database.Chat{JID: chat, Kind: "dm"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{ID: id, ChatJID: chat, Timestamp: 1, Type: "image"}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	raw, err := proto.Marshal(im)
	if err != nil {
		t.Fatalf("marshal image: %v", err)
	}
	media := extractMedia(id, &waE2E.Message{ImageMessage: im})
	if media == nil {
		t.Fatal("extractMedia returned nil")
	}
	media.Proto = raw
	if err := repo.UpsertMedia(ctx, *media); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}
	return raw
}

func TestMediaDownloadStreamsCachesAndWritesThumbnail(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"
	const id = "m1"

	im := &waE2E.ImageMessage{
		Mimetype:      proto.String("image/jpeg"),
		FileLength:    proto.Uint64(4),
		Width:         proto.Uint32(640),
		Height:        proto.Uint32(480),
		FileSHA256:    make([]byte, 32),
		JPEGThumbnail: []byte{0xff, 0xd8, 0xff, 0xd9},
		DirectPath:    proto.String("/v/t62.7118-24/abc"),
		MediaKey:      make([]byte, 32),
	}
	insertMediaMessage(t, repo, ctx, id, chat, im)
	mf.downloadData = []byte("DATA")

	got, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"m1"}`))
	if ipcErr != nil {
		t.Fatalf("MediaDownload: %v", ipcErr)
	}
	res, ok := got.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v", got)
	}
	if res["cached"] != false {
		t.Fatalf("cached = %v, want false", res["cached"])
	}
	if res["kind"] != "image" || res["mime"] != "image/jpeg" {
		t.Fatalf("metadata = %#v", res)
	}
	if res["width"] != 640 || res["height"] != 480 {
		t.Fatalf("dimensions = %v x %v, want 640x480", res["width"], res["height"])
	}
	path, _ := res["path"].(string)
	if path == "" || !fileExists(path) {
		t.Fatalf("path %q does not exist", path)
	}
	if !pathWithin(m.dataDir, path) {
		t.Fatalf("path %q escapes data dir %q", path, m.dataDir)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("media perm = %o, want 600", perm)
	}
	sum := sha256.Sum256(mf.downloadData)
	if filepath.Base(path) != hex.EncodeToString(sum[:])+".jpg" {
		t.Fatalf("media file = %q, want <sha256>.jpg", filepath.Base(path))
	}
	if b, err := os.ReadFile(path); err != nil || string(b) != "DATA" {
		t.Fatalf("media content = %q (%v)", b, err)
	}

	thumb, _ := res["thumb"].(string)
	if thumb == "" || !fileExists(thumb) {
		t.Fatalf("thumb %q does not exist", thumb)
	}
	if filepath.Base(thumb) != hex.EncodeToString(sum[:])+".jpg" {
		t.Fatalf("thumb file = %q, want <sha256>.jpg", filepath.Base(thumb))
	}

	md, err := repo.GetMedia(ctx, id)
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.Status != "done" || md.Path != path || md.ThumbPath != thumb {
		t.Fatalf("persisted media = %+v", md)
	}

	// Second call must be served from cache without a new download.
	mf.downloadData = nil
	got2, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"m1"}`))
	if ipcErr != nil {
		t.Fatalf("MediaDownload cached: %v", ipcErr)
	}
	res2 := got2.(map[string]any)
	if res2["cached"] != true || res2["path"] != path {
		t.Fatalf("cached result = %#v", res2)
	}
}

func TestMediaDownloadErrors(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{ID: "plain", ChatJID: chat, Timestamp: 1, Type: "text"}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}

	// Message exists but has no media.
	if _, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"plain"}`)); ipcErr == nil || ipcErr.Code != CodeNoMedia {
		t.Fatalf("error = %v, want %s", ipcErr, CodeNoMedia)
	}
	// Unknown message.
	if _, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"nope"}`)); ipcErr == nil || ipcErr.Code != CodeNotFound {
		t.Fatalf("error = %v, want %s", ipcErr, CodeNotFound)
	}
	// Missing params.
	if _, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net"}`)); ipcErr == nil || ipcErr.Code != CodeInvalidRequest {
		t.Fatalf("error = %v, want %s", ipcErr, CodeInvalidRequest)
	}
}

func TestMediaDownloadFailureIsStable(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"
	const id = "m1"
	insertMediaMessage(t, repo, ctx, id, chat, &waE2E.ImageMessage{
		Mimetype:   proto.String("image/jpeg"),
		FileSHA256: make([]byte, 32),
		DirectPath: proto.String("/v/t62/abc"),
		MediaKey:   make([]byte, 32),
	})
	mf.downloadErr = os.ErrDeadlineExceeded

	if _, ipcErr := m.MediaDownload(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"m1"}`)); ipcErr == nil || ipcErr.Code != CodeDownloadFailed {
		t.Fatalf("error = %v, want %s", ipcErr, CodeDownloadFailed)
	}
}

func TestChatMessagesIncludesMediaAndReactions(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{ID: "m1", ChatJID: chat, Timestamp: 1, Type: "image", Text: "legenda"}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	// A real file on disk so the payload reports downloaded=true.
	downloaded := filepath.Join(m.dataDir, "cache", "images", "deadbeef.jpg")
	if err := os.MkdirAll(filepath.Dir(downloaded), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(downloaded, []byte("x"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := repo.UpsertMedia(ctx, database.Media{
		ID: "m1", MessageID: "m1", Kind: "image", Mime: "image/jpeg", Size: 4, Width: 10, Height: 20,
	}); err != nil {
		t.Fatalf("UpsertMedia: %v", err)
	}
	if err := repo.MarkMediaDownloaded(ctx, "m1", downloaded, "deadbeef", ""); err != nil {
		t.Fatalf("MarkMediaDownloaded: %v", err)
	}
	if err := repo.UpsertReaction(ctx, database.Reaction{
		MessageID: "m1", ChatJID: chat, SenderJID: "bob@s.whatsapp.net", Emoji: "👍", Timestamp: 2,
	}); err != nil {
		t.Fatalf("UpsertReaction: %v", err)
	}

	got, ipcErr := m.ChatMessages(ctx, json.RawMessage(`{"jid":"a@s.whatsapp.net","limit":10}`))
	if ipcErr != nil {
		t.Fatalf("ChatMessages: %v", ipcErr)
	}
	msgs, ok := got.([]map[string]any)
	if !ok || len(msgs) != 1 {
		t.Fatalf("result = %#v", got)
	}
	media, ok := msgs[0]["media"].(map[string]any)
	if !ok {
		t.Fatalf("media missing: %#v", msgs[0])
	}
	if media["kind"] != "image" || media["mime"] != "image/jpeg" || media["downloaded"] != true {
		t.Fatalf("media = %#v", media)
	}
	if media["width"] != 10 || media["height"] != 20 {
		t.Fatalf("media dims = %#v", media)
	}
	reactions, ok := msgs[0]["reactions"].([]map[string]any)
	if !ok || len(reactions) != 1 {
		t.Fatalf("reactions = %#v", msgs[0]["reactions"])
	}
	if reactions[0]["emoji"] != "👍" || reactions[0]["sender"] != "bob@s.whatsapp.net" || reactions[0]["from_me"] != false {
		t.Fatalf("reaction = %#v", reactions[0])
	}
}

func TestMessageReactSendsPersistsAndEmits(t *testing.T) {
	m, svc, mf, repo, ctx := newTestMethods(t)
	const chat = "a@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{
		ID: "m1", ChatJID: chat, SenderJID: "bob@s.whatsapp.net", Timestamp: 1, Type: "text",
	}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}

	got, ipcErr := m.MessageReact(ctx, json.RawMessage(`{"chat":"a@s.whatsapp.net","id":"m1","emoji":"x"}`))
	if ipcErr != nil {
		t.Fatalf("MessageReact: %v", ipcErr)
	}
	if res, ok := got.(map[string]any); !ok || res["ok"] != true {
		t.Fatalf("result = %#v", got)
	}
	rm := mf.sentMsg.GetReactionMessage()
	if rm == nil || rm.GetText() != "x" {
		t.Fatalf("reaction message = %+v", rm)
	}
	if rm.GetKey().GetID() != "m1" || rm.GetKey().GetParticipant() != "bob@s.whatsapp.net" {
		t.Fatalf("reaction key = %+v", rm.GetKey())
	}

	reactions, err := repo.ListReactions(ctx, "m1")
	if err != nil {
		t.Fatalf("ListReactions: %v", err)
	}
	if len(reactions) != 1 || reactions[0].Emoji != "x" || !reactions[0].FromMe {
		t.Fatalf("persisted reactions = %+v", reactions)
	}

	ev := readEvent(t, svc.Events(), EventMessageUpdated)
	reaction, ok := ev.Data["reaction"].(map[string]any)
	if !ok || reaction["emoji"] != "x" || reaction["sender"] == "" {
		t.Fatalf("message.updated = %#v", ev.Data)
	}
}

func TestPersistMediaCreatesMediaRow(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	im := &waE2E.ImageMessage{
		Mimetype:   proto.String("image/jpeg"),
		FileLength: proto.Uint64(10),
		Width:      proto.Uint32(100),
		Height:     proto.Uint32(50),
		FileSHA256: make([]byte, 32),
		DirectPath: proto.String("/v/t62/abc"),
		MediaKey:   make([]byte, 32),
	}
	ev := testMessage("m1", "a@s.whatsapp.net", "bob@s.whatsapp.net", false, 1, "")
	ev.Message = &waE2E.Message{ImageMessage: im}

	if err := p.persistMessage(ctx, ev); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	md, err := repo.GetMedia(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.Kind != "image" || md.Mime != "image/jpeg" || md.Size != 10 || md.Width != 100 || md.Height != 50 {
		t.Fatalf("media row = %+v", md)
	}
	if len(md.Proto) == 0 {
		t.Fatal("download proto was not persisted")
	}
	sub, err := decodeDownloadable(md.Kind, md.Proto)
	if err != nil {
		t.Fatalf("decodeDownloadable: %v", err)
	}
	if _, ok := sub.(*waE2E.ImageMessage); !ok {
		t.Fatalf("decoded %T, want *waE2E.ImageMessage", sub)
	}

	// Re-persisting must not clobber download state.
	if err := repo.MarkMediaDownloaded(ctx, "m1", "/tmp/x.jpg", "abc", ""); err != nil {
		t.Fatalf("MarkMediaDownloaded: %v", err)
	}
	ev2 := testMessage("m1", "a@s.whatsapp.net", "bob@s.whatsapp.net", false, 1, "")
	ev2.Message = &waE2E.Message{ImageMessage: im}
	if err := p.persistMessage(ctx, ev2); err != nil {
		t.Fatalf("re-persist: %v", err)
	}
	md2, err := repo.GetMedia(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMedia after re-persist: %v", err)
	}
	if md2.Path != "/tmp/x.jpg" || md2.Status != "done" {
		t.Fatalf("download state was clobbered: %+v", md2)
	}
}
