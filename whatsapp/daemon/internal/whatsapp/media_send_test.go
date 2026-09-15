package whatsapp

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
)

// writePNG writes a small valid PNG to path and returns its size.
func writePNG(t *testing.T, path string, w, h int) int64 {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 4), G: uint8(y * 4), B: 128, A: 255})
		}
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create %q: %v", path, err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	info, err := f.Stat()
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	return info.Size()
}

func writeBytes(t *testing.T, path string, data []byte) int64 {
	t.Helper()
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write %q: %v", path, err)
	}
	return int64(len(data))
}

func mediaSend(t *testing.T, m *Methods, ctx context.Context, params map[string]any) (map[string]any, *ipc.Error) {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("marshal params: %v", err)
	}
	got, ipcErr := m.MediaSend(ctx, raw)
	if ipcErr != nil {
		return nil, ipcErr
	}
	outer, ok := got.(map[string]any)
	if !ok || outer["ok"] != true {
		t.Fatalf("result = %#v, want {ok:true,...}", got)
	}
	res, ok := outer["result"].(map[string]any)
	if !ok {
		t.Fatalf("result payload = %#v", outer["result"])
	}
	return res, nil
}

func TestMediaSendImageCachesPersistsAndEmits(t *testing.T) {
	m, svc, mf, repo, ctx := newTestMethods(t)
	ctx = ipc.WithRequestID(ctx, 7)

	dir := t.TempDir()
	imgPath := filepath.Join(dir, "pic.png")
	size := writePNG(t, imgPath, 64, 64)
	// whatsmeow reports the plaintext length; mirror that in the fake.
	mf.uploadResp.FileLength = uint64(size)

	res, ipcErr := mediaSend(t, m, ctx, map[string]any{
		"chat":    "bob@s.whatsapp.net",
		"path":    imgPath,
		"caption": "olha isso",
	})
	if ipcErr != nil {
		t.Fatalf("MediaSend: %v", ipcErr)
	}
	if res["id"] != "server-id-1" || res["kind"] != "image" || res["mime"] != "image/png" {
		t.Fatalf("result = %#v", res)
	}
	if res["size"] != size {
		t.Fatalf("size = %v, want %d", res["size"], size)
	}
	if res["width"] != 64 || res["height"] != 64 {
		t.Fatalf("dimensions = %v x %v, want 64x64", res["width"], res["height"])
	}
	if res["caption"] != "olha isso" {
		t.Fatalf("caption = %v", res["caption"])
	}

	path, _ := res["path"].(string)
	if path == "" || !fileExists(path) || !pathWithin(m.dataDir, path) {
		t.Fatalf("cache path %q invalid", path)
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("cache perms: err=%v", err)
	}
	thumb, _ := res["thumb"].(string)
	if thumb == "" || !fileExists(thumb) || !pathWithin(m.dataDir, thumb) {
		t.Fatalf("thumb path %q invalid", thumb)
	}

	if mf.uploadApp != whatsmeow.MediaImage {
		t.Fatalf("upload appInfo = %q, want %q", mf.uploadApp, whatsmeow.MediaImage)
	}
	im := mf.sentMsg.GetImageMessage()
	if im == nil {
		t.Fatalf("sent message is not an image: %+v", mf.sentMsg)
	}
	if im.GetCaption() != "olha isso" {
		t.Fatalf("proto caption = %q", im.GetCaption())
	}
	if len(im.GetJPEGThumbnail()) == 0 {
		t.Fatal("image proto has no embedded thumbnail")
	}
	if len(im.GetMediaKey()) != 32 || im.GetFileLength() != uint64(size) {
		t.Fatalf("image proto upload fields = %+v", im)
	}

	md, err := repo.GetMedia(ctx, "server-id-1")
	if err != nil {
		t.Fatalf("GetMedia: %v", err)
	}
	if md.Status != "done" || md.Path != path || md.ThumbPath != thumb || md.Kind != "image" {
		t.Fatalf("cae_media = %+v", md)
	}
	msg, err := repo.GetMessage(ctx, "server-id-1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if !msg.FromMe || msg.Type != "image" || msg.Text != "olha isso" {
		t.Fatalf("persisted message = %+v", msg)
	}

	// Progress events carry the request temp_id and reach 100; the local send
	// emits message.received once and chat.updated.
	var pcts []int
	var tempIDs []string
	sawReceived := false
	deadline := time.After(2 * time.Second)
	for !sawReceived {
		select {
		case ev := <-svc.Events():
			switch ev.Name {
			case EventMediaUpload:
				pcts = append(pcts, ev.Data["pct"].(int))
				tempIDs = append(tempIDs, ev.Data["temp_id"].(string))
			case EventMessageReceived:
				sawReceived = true
			}
		case <-deadline:
			t.Fatal("timed out waiting for message.received")
		}
	}
	if len(pcts) == 0 || pcts[0] != 0 || pcts[len(pcts)-1] != 100 {
		t.Fatalf("progress pcts = %v, want 0..100", pcts)
	}
	for _, id := range tempIDs {
		if id != "7" {
			t.Fatalf("temp_id = %q, want 7", id)
		}
	}
	// The chat.updated emitted right after message.received.
	ev := readEvent(t, svc.Events(), EventChatUpdated)
	if ev.Data["jid"] != "bob@s.whatsapp.net" {
		t.Fatalf("chat.updated = %#v", ev.Data)
	}
}

func TestMediaSendKinds(t *testing.T) {
	pdf := []byte("%PDF-1.4\n%fake pdf\n")
	cases := []struct {
		name     string
		ext      string
		data     []byte
		png      bool
		wantKind string
		wantMime string
		wantApp  whatsmeow.MediaType
	}{
		{name: "image", ext: "png", png: true, wantKind: "image", wantMime: "image/png", wantApp: whatsmeow.MediaImage},
		{name: "video", ext: "mp4", data: []byte("....ftypisom-fake"), wantKind: "video", wantMime: "video/mp4", wantApp: whatsmeow.MediaVideo},
		{name: "audio-ogg", ext: "ogg", data: []byte("OggS-fake"), wantKind: "audio", wantMime: "audio/ogg", wantApp: whatsmeow.MediaAudio},
		{name: "audio-opus", ext: "opus", data: []byte("OggS-fake"), wantKind: "audio", wantMime: "audio/ogg; codecs=opus", wantApp: whatsmeow.MediaAudio},
		{name: "document", ext: "pdf", data: pdf, wantKind: "document", wantMime: "application/pdf", wantApp: whatsmeow.MediaDocument},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, _, mf, _, ctx := newTestMethods(t)
			path := filepath.Join(t.TempDir(), "file."+tc.ext)
			if tc.png {
				writePNG(t, path, 8, 8)
			} else {
				writeBytes(t, path, tc.data)
			}
			res, ipcErr := mediaSend(t, m, ctx, map[string]any{"chat": "bob@s.whatsapp.net", "path": path})
			if ipcErr != nil {
				t.Fatalf("MediaSend: %v", ipcErr)
			}
			if res["kind"] != tc.wantKind || res["mime"] != tc.wantMime {
				t.Fatalf("result kind/mime = %v/%v, want %v/%v", res["kind"], res["mime"], tc.wantKind, tc.wantMime)
			}
			if mf.uploadApp != tc.wantApp {
				t.Fatalf("appInfo = %q, want %q", mf.uploadApp, tc.wantApp)
			}
			switch tc.wantKind {
			case "image":
				if mf.sentMsg.GetImageMessage() == nil {
					t.Fatal("not an ImageMessage")
				}
			case "video":
				if mf.sentMsg.GetVideoMessage() == nil {
					t.Fatal("not a VideoMessage")
				}
			case "audio":
				am := mf.sentMsg.GetAudioMessage()
				if am == nil || !am.GetPTT() {
					t.Fatalf("not a PTT AudioMessage: %+v", am)
				}
			case "document":
				dm := mf.sentMsg.GetDocumentMessage()
				if dm == nil || dm.GetFileName() != "file.pdf" {
					t.Fatalf("document = %+v", dm)
				}
			}
		})
	}
}

func TestMediaSendCaptionAndReply(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)
	const chat = "bob@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: chat}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{
		ID: "q1", ChatJID: chat, SenderJID: "carol@s.whatsapp.net", Timestamp: 1, Type: "text",
	}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	path := filepath.Join(t.TempDir(), "pic.png")
	writePNG(t, path, 4, 4)

	if _, ipcErr := mediaSend(t, m, ctx, map[string]any{
		"chat": chat, "path": path, "caption": "resposta", "reply_to": "q1",
	}); ipcErr != nil {
		t.Fatalf("MediaSend: %v", ipcErr)
	}
	im := mf.sentMsg.GetImageMessage()
	if im == nil || im.GetCaption() != "resposta" {
		t.Fatalf("image = %+v", im)
	}
	ci := im.GetContextInfo()
	if ci == nil || ci.GetStanzaID() != "q1" || ci.GetParticipant() != "carol@s.whatsapp.net" {
		t.Fatalf("context info = %+v", ci)
	}
}

func TestMediaSendErrors(t *testing.T) {
	m, _, mf, _, ctx := newTestMethods(t)
	const chat = "bob@s.whatsapp.net"

	pngPath := filepath.Join(t.TempDir(), "ok.png")
	writePNG(t, pngPath, 4, 4)

	// A directory is not a regular file.
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": t.TempDir()})); err == nil || err.Code != CodeInvalidRequest {
		t.Fatalf("dir error = %v, want %s", err, CodeInvalidRequest)
	}
	// Relative path.
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": "relative.png"})); err == nil || err.Code != CodeInvalidRequest {
		t.Fatalf("relative error = %v, want %s", err, CodeInvalidRequest)
	}
	// Missing file.
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": filepath.Join(t.TempDir(), "nope.png")})); err == nil || err.Code != CodeFileNotFound {
		t.Fatalf("missing error = %v, want %s", err, CodeFileNotFound)
	}
	// Too large.
	big := filepath.Join(t.TempDir(), "big.png")
	if err := os.WriteFile(big, []byte("x"), 0o600); err != nil {
		t.Fatalf("write big: %v", err)
	}
	if err := os.Truncate(big, maxMediaSendBytes+1); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": big})); err == nil || err.Code != CodeFileTooLarge {
		t.Fatalf("large error = %v, want %s", err, CodeFileTooLarge)
	}
	// Unsupported content (BMP is image/* but not supported).
	bmp := filepath.Join(t.TempDir(), "not-supported.bmp")
	writeBytes(t, bmp, append([]byte("BM"), bytes.Repeat([]byte{0}, 64)...))
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": bmp})); err == nil || err.Code != CodeUnsupportedType {
		t.Fatalf("unsupported error = %v, want %s", err, CodeUnsupportedType)
	}
	// Upload failure.
	mf.uploadErr = context.DeadlineExceeded
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": pngPath})); err == nil || err.Code != CodeUploadFailed {
		t.Fatalf("upload error = %v, want %s", err, CodeUploadFailed)
	}
	// Send failure.
	mf.uploadErr = nil
	mf.sendErr = context.DeadlineExceeded
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": chat, "path": pngPath})); err == nil || err.Code != CodeSendFailed {
		t.Fatalf("send error = %v, want %s", err, CodeSendFailed)
	}
}

func TestMediaSendNotPaired(t *testing.T) {
	m, svc, _, _, ctx := newTestMethods(t)
	setDevice(svc, &store.Device{})

	path := filepath.Join(t.TempDir(), "pic.png")
	writePNG(t, path, 4, 4)
	if _, err := m.MediaSend(ctx, mustJSON(t, map[string]any{"chat": "bob@s.whatsapp.net", "path": path})); err == nil || err.Code != CodeNotPaired {
		t.Fatalf("error = %v, want %s", err, CodeNotPaired)
	}
}

func TestProgressReaderThrottlesAndReaches100(t *testing.T) {
	var got []int
	pr := &progressReader{r: bytes.NewReader(make([]byte, 100)), total: 100, emit: func(p int) { got = append(got, p) }}
	buf := make([]byte, 10)
	for {
		if _, err := pr.Read(buf); err != nil {
			break
		}
	}
	if len(got) == 0 || got[len(got)-1] != 100 {
		t.Fatalf("pcts = %v, want final 100", got)
	}
	if len(got) > 21 {
		t.Fatalf("emitted %d progress events, want <= 21 (~5%% throttle)", len(got))
	}
	for i := 1; i < len(got); i++ {
		if got[i] <= got[i-1] {
			t.Fatalf("pcts not strictly increasing: %v", got)
		}
	}
	n := len(got)
	pr.force(100)
	if len(got) != n {
		t.Fatalf("force emitted on an already-complete reader: %v", got)
	}
}

func TestClassifyMediaFileUnsupportedAndDocument(t *testing.T) {
	dir := t.TempDir()
	txt := filepath.Join(dir, "notes.txt")
	writeBytes(t, txt, []byte("hello"))
	kind, mime, err := classifyMediaFile(txt)
	if err != nil || kind != "document" || mime != "text/plain" {
		t.Fatalf("txt = (%q,%q,%v), want document/text/plain", kind, mime, err)
	}
	unknown := filepath.Join(dir, "blob.bin")
	writeBytes(t, unknown, bytes.Repeat([]byte{0x00, 0x01}, 32))
	kind, mime, err = classifyMediaFile(unknown)
	if err != nil || kind != "document" || mime != "application/octet-stream" {
		t.Fatalf("bin = (%q,%q,%v), want document/octet-stream", kind, mime, err)
	}
}

// mustJSON marshals params for a direct MediaSend call.
func mustJSON(t *testing.T, params map[string]any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return raw
}
