package whatsapp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	"image/jpeg"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	// Register the image decoders used for thumbnails/dimensions. JPEG is also
	// imported normally below for encoding.
	_ "image/gif"
	_ "image/png"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// errUnsupportedMediaType is returned when a file is neither a supported
// image/video/audio nor a safe generic document.
var errUnsupportedMediaType = errors.New("whatsapp: unsupported media type")

// thumbnailMaxSide is the longest side of a generated image thumbnail.
const thumbnailMaxSide = 256

// --- media.send ---

type mediaSendParams struct {
	Chat    string `json:"chat"`
	Path    string `json:"path"`
	Caption string `json:"caption"`
	ReplyTo string `json:"reply_to"`
}

// MediaSend uploads a local file to WhatsApp as an image, video, voice note or
// document, sends it to a chat (optionally as a reply and/or with a caption),
// then caches a copy and persists the message. Progress is announced with
// media.upload events carrying the request temp_id.
func (m *Methods) MediaSend(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p mediaSendParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	chat := strings.TrimSpace(p.Chat)
	srcPath := strings.TrimSpace(p.Path)
	if chat == "" || srcPath == "" {
		return nil, invalidRequest("chat and path are required")
	}
	jid, err := parseJID(chat)
	if err != nil {
		return nil, invalidRequest("invalid jid: " + err.Error())
	}
	if !filepath.IsAbs(srcPath) {
		return nil, invalidRequest("path must be absolute")
	}
	info, err := os.Stat(srcPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, &ipc.Error{Code: CodeFileNotFound, Message: "whatsapp: file not found"}
		}
		return nil, invalidRequest("cannot stat path: " + err.Error())
	}
	if !info.Mode().IsRegular() {
		return nil, invalidRequest("path is not a regular file")
	}
	if info.Size() > maxMediaSendBytes {
		return nil, &ipc.Error{Code: CodeFileTooLarge, Message: "whatsapp: file exceeds 100 MB"}
	}
	if info.Size() == 0 {
		return nil, invalidRequest("file is empty")
	}
	kind, mime, cerr := classifyMediaFile(srcPath)
	if cerr != nil {
		return nil, &ipc.Error{Code: CodeUnsupportedType, Message: "whatsapp: unsupported media type"}
	}

	c := m.svc.fullClient()
	if c == nil {
		return nil, &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}
	ctxInfo := m.mediaContextInfo(ctx, p.ReplyTo, jid)

	// A generated thumbnail is embedded in the image proto so recipients can
	// preview it without downloading the full file.
	var thumbJPEG []byte
	var width, height int
	if kind == mediaKindImage {
		thumbJPEG, width, height = imageThumbnail(srcPath)
	}

	// Scratch file for whatsmeow's encryption pass. The plaintext source is
	// kept separate so the original file survives for the cache copy.
	tmp, err := os.CreateTemp("", "cw-media-send-*")
	if err != nil {
		return nil, internalError(err)
	}
	tmpName := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}()

	src, err := os.Open(srcPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, &ipc.Error{Code: CodeFileNotFound, Message: "whatsapp: file not found"}
		}
		return nil, invalidRequest("cannot open path: " + err.Error())
	}
	defer src.Close()

	emit := func(pct int) {
		m.svc.emit(EventMediaUpload, map[string]any{
			"temp_id": ipc.StringID(ipc.RequestIDFromContext(ctx)),
			"chat":    chat,
			"pct":     pct,
		})
	}
	emit(0)
	progress := &progressReader{r: src, total: info.Size(), emit: emit}

	upCtx, cancelUp := context.WithTimeout(ctx, mediaUploadTimeout)
	defer cancelUp()
	up, err := c.UploadReader(upCtx, progress, tmp, mediaTypeForKind(kind))
	if err != nil {
		m.logger.Warn("whatsapp: media upload failed",
			slog.String("chat", logging.RedactJID(chat)),
			slog.String("kind", kind),
			slog.String("error", err.Error()))
		return nil, &ipc.Error{Code: CodeUploadFailed, Message: "whatsapp: media upload failed"}
	}
	progress.force(100)

	message := buildMediaMessage(kind, mime, p.Caption, thumbJPEG, width, height, srcPath, up, ctxInfo)
	sendCtx, cancelSend := context.WithTimeout(ctx, sendTimeout)
	defer cancelSend()
	resp, err := c.SendMessage(sendCtx, jid, message)
	if err != nil {
		m.logger.Warn("whatsapp: media send failed",
			slog.String("chat", logging.RedactJID(chat)),
			slog.String("kind", kind),
			slog.String("error", err.Error()))
		return nil, &ipc.Error{Code: CodeSendFailed, Message: "whatsapp: send failed"}
	}

	id := string(resp.ID)
	ts := resp.Timestamp.UnixMilli()
	result, perr := m.finalizeSentMedia(ctx, jid, id, srcPath, kind, mime, p.Caption, width, height, thumbJPEG, message, ts)
	if perr != nil {
		// The message is already sent; a cache/persist failure must not turn
		// the send into an error. Report the metadata without the paths.
		m.logger.Warn("whatsapp: persist sent media failed",
			slog.String("chat", logging.RedactJID(chat)),
			slog.String("error", perr.Error()))
		result = map[string]any{
			"id": id, "kind": kind, "mime": mime, "size": info.Size(),
			"width": width, "height": height, "path": "", "thumb": nil, "caption": p.Caption,
		}
	}
	return map[string]any{"ok": true, "result": result}, nil
}

// finalizeSentMedia caches a copy of the just-sent file, writes the thumbnail,
// persists the message plus cae_media (downloaded=done) and emits the local
// message.received/chat.updated so the frontend updates without waiting for the
// server echo (which dedupes by message id).
func (m *Methods) finalizeSentMedia(
	ctx context.Context,
	jid types.JID,
	id, srcPath, kind, mime, caption string,
	width, height int,
	thumbJPEG []byte,
	message *waE2E.Message,
	ts int64,
) (map[string]any, error) {
	final, sha, err := m.copyToCache(srcPath, kind, mime)
	if err != nil {
		return nil, err
	}
	thumbPath := ""
	if kind == mediaKindImage && len(thumbJPEG) > 0 {
		if tp, terr := m.writeThumbnail(sha, thumbJPEG); terr == nil {
			thumbPath = tp
		} else {
			m.logger.Warn("whatsapp: thumbnail write failed", slog.String("error", terr.Error()))
		}
	}

	md := extractMedia(id, message)
	if md == nil {
		md = &database.Media{ID: id, MessageID: id, Kind: kind, Mime: mime}
	}
	md.Path = final
	md.SHA256 = sha
	md.Status = "done"
	md.ThumbPath = thumbPath

	chatJID := jid.String()
	selfJID := m.svc.AuthStatus().JID
	if err := m.repo.UpsertChat(ctx, database.Chat{
		JID:  chatJID,
		Kind: kindForJID(jid),
		Name: m.chatName(ctx, chatJID),
	}); err != nil {
		return nil, err
	}
	// The message row must exist before cae_media: its message_id has a foreign
	// key to cae_messages(id).
	inserted, err := m.repo.InsertMessage(ctx, database.Message{
		ID:        id,
		ChatJID:   chatJID,
		SenderJID: selfJID,
		FromMe:    true,
		Timestamp: ts,
		Type:      kind,
		Text:      caption,
		QuotedID:  replyID(message),
		Status:    "sent",
		MediaID:   id,
	})
	if err != nil {
		return nil, err
	}
	if err := m.repo.UpsertMedia(ctx, *md); err != nil {
		return nil, err
	}
	if err := m.repo.MarkMediaDownloaded(ctx, id, final, sha, thumbPath); err != nil {
		return nil, err
	}
	if inserted {
		if err := m.repo.UpdateChatLastMessage(ctx, chatJID, id, ts, preview(caption, kind)); err != nil {
			return nil, err
		}
		m.svc.emit(EventMessageReceived, map[string]any{
			"chat":      chatJID,
			"sender":    selfJID,
			"id":        id,
			"text":      caption,
			"timestamp": ipc.StringTimestamp(ts),
			"from_me":   true,
			"type":      kind,
		})
		if c, cerr := m.repo.GetChat(ctx, chatJID); cerr == nil {
			m.svc.emit(EventChatUpdated, chatUpdatedData(c))
		}
	}

	var thumb any
	if thumbPath != "" {
		thumb = thumbPath
	}
	return map[string]any{
		"id":      id,
		"kind":    kind,
		"mime":    mime,
		"size":    fileSizeOrZero(srcPath),
		"width":   width,
		"height":  height,
		"path":    final,
		"thumb":   thumb,
		"caption": caption,
	}, nil
}

// copyToCache copies srcPath into cache/<kind-dir>/<sha256>.<ext> with 0600
// permissions, atomically. It returns the absolute cache path and the digest.
func (m *Methods) copyToCache(srcPath, kind, mime string) (string, string, error) {
	sha, err := fileSHA256Hex(srcPath)
	if err != nil {
		return "", "", err
	}
	dir := filepath.Join(m.cacheDir, mediaDirName(kind))
	if err := os.MkdirAll(dir, database.DirPerm); err != nil {
		return "", "", err
	}
	ext := mediaExtension(kind, mime, filepath.Base(srcPath))
	final := filepath.Join(dir, sha+"."+ext)
	if !pathWithin(dir, final) {
		return "", "", errors.New("whatsapp: cache path escapes data dir")
	}
	if fileExists(final) {
		return final, sha, nil
	}
	src, err := os.Open(srcPath)
	if err != nil {
		return "", "", err
	}
	defer src.Close()
	tmp, err := os.CreateTemp(dir, ".send-*")
	if err != nil {
		return "", "", err
	}
	tmpPath := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := io.Copy(tmp, src); err != nil {
		return "", "", err
	}
	if err := tmp.Close(); err != nil {
		return "", "", err
	}
	if err := os.Rename(tmpPath, final); err != nil {
		return "", "", err
	}
	if err := os.Chmod(final, database.FilePerm); err != nil {
		return "", "", err
	}
	ok = true
	return final, sha, nil
}

// mediaContextInfo builds the ContextInfo for a reply, resolving the quoted
// message's sender when known. It returns nil when replyTo is empty.
func (m *Methods) mediaContextInfo(ctx context.Context, replyTo string, jid types.JID) *waE2E.ContextInfo {
	replyTo = strings.TrimSpace(replyTo)
	if replyTo == "" {
		return nil
	}
	sender := jid.String()
	if ref, err := m.repo.GetMessage(ctx, replyTo); err == nil && ref.SenderJID != "" {
		sender = ref.SenderJID
	}
	return &waE2E.ContextInfo{
		StanzaID:    proto.String(replyTo),
		Participant: proto.String(sender),
	}
}

// replyID extracts the quoted stanza id from an already-built message.
func replyID(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	switch {
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetContextInfo().GetStanzaID()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetContextInfo().GetStanzaID()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage().GetContextInfo().GetStanzaID()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetContextInfo().GetStanzaID()
	default:
		return ""
	}
}

// buildMediaMessage copies an upload response into the matching protobuf
// message, attaching the caption, thumbnail, dimensions and reply context.
func buildMediaMessage(
	kind, mime, caption string,
	thumbJPEG []byte,
	width, height int,
	srcPath string,
	up whatsmeow.UploadResponse,
	ci *waE2E.ContextInfo,
) *waE2E.Message {
	url := up.URL
	direct := up.DirectPath
	length := up.FileLength
	switch kind {
	case mediaKindImage:
		im := &waE2E.ImageMessage{
			URL:           &url,
			DirectPath:    &direct,
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    &length,
			Mimetype:      proto.String(mime),
		}
		if caption != "" {
			im.Caption = proto.String(caption)
		}
		if len(thumbJPEG) > 0 {
			im.JPEGThumbnail = thumbJPEG
		}
		if width > 0 {
			im.Width = proto.Uint32(uint32(width))
		}
		if height > 0 {
			im.Height = proto.Uint32(uint32(height))
		}
		if ci != nil {
			im.ContextInfo = ci
		}
		return &waE2E.Message{ImageMessage: im}
	case mediaKindVideo:
		vm := &waE2E.VideoMessage{
			URL:           &url,
			DirectPath:    &direct,
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    &length,
			Mimetype:      proto.String(mime),
		}
		if caption != "" {
			vm.Caption = proto.String(caption)
		}
		if ci != nil {
			vm.ContextInfo = ci
		}
		return &waE2E.Message{VideoMessage: vm}
	case mediaKindAudio:
		am := &waE2E.AudioMessage{
			URL:           &url,
			DirectPath:    &direct,
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    &length,
			Mimetype:      proto.String(mime),
			PTT:           proto.Bool(true),
		}
		if ci != nil {
			am.ContextInfo = ci
		}
		return &waE2E.Message{AudioMessage: am}
	default:
		name := filepath.Base(srcPath)
		dm := &waE2E.DocumentMessage{
			URL:           &url,
			DirectPath:    &direct,
			MediaKey:      up.MediaKey,
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    &length,
			Mimetype:      proto.String(mime),
			FileName:      proto.String(name),
			Title:         proto.String(name),
		}
		if caption != "" {
			dm.Caption = proto.String(caption)
		}
		if ci != nil {
			dm.ContextInfo = ci
		}
		return &waE2E.Message{DocumentMessage: dm}
	}
}

// mediaTypeForKind maps an IPC media kind to the whatsmeow key-derivation type.
func mediaTypeForKind(kind string) whatsmeow.MediaType {
	switch kind {
	case mediaKindImage:
		return whatsmeow.MediaImage
	case mediaKindVideo:
		return whatsmeow.MediaVideo
	case mediaKindAudio:
		return whatsmeow.MediaAudio
	default:
		return whatsmeow.MediaDocument
	}
}

// progressReader counts plaintext bytes read during the upload/encryption pass
// and reports percent progress, throttled to ~5% steps. whatsmeow does not
// expose an upload callback, so this is the only progress signal available.
type progressReader struct {
	r       io.Reader
	total   int64
	read    int64
	lastPct int
	emit    func(int)
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.read += int64(n)
	if p.total > 0 && p.emit != nil {
		pct := int(p.read * 100 / p.total)
		if pct > 100 {
			pct = 100
		}
		if pct >= p.lastPct+5 {
			p.lastPct = pct
			p.emit(pct)
		}
	}
	return n, err
}

// force emits a final percent (used for the 100% mark after upload).
func (p *progressReader) force(pct int) {
	if p.emit != nil && p.lastPct < pct {
		p.lastPct = pct
		p.emit(pct)
	}
}

// classifyMediaFile determines the media kind and MIME type of a file from its
// extension and content. Unsupported rich media (e.g. bmp, webm, quicktime)
// are rejected; any other regular file becomes a document.
func classifyMediaFile(path string) (kind, mime string, err error) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	sniff := sniffContentType(path)
	extKind, extMime, extOK := mediaKindByExtension(ext)
	snKind, snRich := sniffRichKind(sniff)
	if extOK {
		if snRich && snKind != extKind {
			return "", "", errUnsupportedMediaType
		}
		return extKind, extMime, nil
	}
	if snRich {
		switch snKind {
		case mediaKindImage:
			if k, m, ok := supportedImageSniff(sniff); ok {
				return k, m, nil
			}
			return "", "", errUnsupportedMediaType
		case mediaKindVideo:
			if sniff == "video/mp4" {
				return mediaKindVideo, "video/mp4", nil
			}
			return "", "", errUnsupportedMediaType
		default: // audio (ogg/opus)
			return mediaKindAudio, "audio/ogg", nil
		}
	}
	if mime = strings.TrimSpace(strings.SplitN(sniff, ";", 2)[0]); mime == "" {
		mime = "application/octet-stream"
	}
	return mediaKindDocument, mime, nil
}

// mediaKindByExtension maps a supported file extension to its kind and MIME.
func mediaKindByExtension(ext string) (kind, mime string, ok bool) {
	switch ext {
	case "jpg", "jpeg":
		return mediaKindImage, "image/jpeg", true
	case "png":
		return mediaKindImage, "image/png", true
	case "gif":
		return mediaKindImage, "image/gif", true
	case "webp":
		return mediaKindImage, "image/webp", true
	case "mp4":
		return mediaKindVideo, "video/mp4", true
	case "ogg":
		return mediaKindAudio, "audio/ogg", true
	case "opus":
		return mediaKindAudio, "audio/ogg; codecs=opus", true
	default:
		return "", "", false
	}
}

// supportedImageSniff maps a sniffed image content type to a supported image.
func supportedImageSniff(ct string) (kind, mime string, ok bool) {
	switch ct {
	case "image/jpeg":
		return mediaKindImage, "image/jpeg", true
	case "image/png":
		return mediaKindImage, "image/png", true
	case "image/gif":
		return mediaKindImage, "image/gif", true
	case "image/webp":
		return mediaKindImage, "image/webp", true
	default:
		return "", "", false
	}
}

// sniffRichKind classifies a content type into the rich kinds we special-case.
// Generic/unknown types return ("", false) so they fall through to document.
func sniffRichKind(ct string) (kind string, rich bool) {
	switch {
	case strings.HasPrefix(ct, "image/"):
		return mediaKindImage, true
	case strings.HasPrefix(ct, "video/"):
		return mediaKindVideo, true
	case ct == "audio/ogg", ct == "application/ogg", ct == "audio/opus":
		return mediaKindAudio, true
	default:
		return "", false
	}
}

// sniffContentType reads the first bytes of a file and returns its sniffed MIME
// type (http.DetectContentType), or "" when the file cannot be read.
func sniffContentType(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf := make([]byte, 512)
	n, _ := f.Read(buf)
	return http.DetectContentType(buf[:n])
}

// imageThumbnail decodes an image and returns a small JPEG thumbnail plus its
// original dimensions. It returns no thumbnail (but possibly dimensions) for
// formats the standard library cannot decode.
func imageThumbnail(path string) (thumb []byte, width, height int) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, 0
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		// WebP is not decodable with the standard library; recover dimensions
		// from its header anyway.
		if w, h := webpDimensions(data); w > 0 && h > 0 {
			return nil, w, h
		}
		return nil, 0, 0
	}
	width, height = cfg.Width, cfg.Height
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, width, height
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, nearestDownscale(img, thumbnailMaxSide), &jpeg.Options{Quality: 80}); err != nil {
		return nil, width, height
	}
	return buf.Bytes(), width, height
}

// nearestDownscale shrinks src so its longest side is at most max, using
// nearest-neighbor sampling (no external image dependency).
func nearestDownscale(src image.Image, max int) image.Image {
	b := src.Bounds()
	sw, sh := b.Dx(), b.Dy()
	if sw <= 0 || sh <= 0 || (sw <= max && sh <= max) {
		return src
	}
	long := sw
	if sh > long {
		long = sh
	}
	dw := sw * max / long
	dh := sh * max / long
	if dw < 1 {
		dw = 1
	}
	if dh < 1 {
		dh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		sy := b.Min.Y + y*sh/dh
		for x := 0; x < dw; x++ {
			sx := b.Min.X + x*sw/dw
			dst.Set(x, y, src.At(sx, sy))
		}
	}
	return dst
}

// stringWriter is no longer used; bytes.Buffer covers encoding.

// webpDimensions parses the dimensions out of a WebP header (VP8/VP8L/VP8X).
func webpDimensions(data []byte) (int, int) {
	if len(data) < 30 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WEBP" {
		return 0, 0
	}
	switch string(data[12:16]) {
	case "VP8 ":
		w := int(data[26]) | int(data[27])<<8
		h := int(data[28]) | int(data[29])<<8
		return w & 0x3fff, h & 0x3fff
	case "VP8L":
		if len(data) < 25 {
			return 0, 0
		}
		bits := uint32(data[21]) | uint32(data[22])<<8 | uint32(data[23])<<16 | uint32(data[24])<<24
		return int(bits&0x3fff) + 1, int((bits>>14)&0x3fff) + 1
	case "VP8X":
		w := int(data[24]) | int(data[25])<<8 | int(data[26])<<16
		h := int(data[27]) | int(data[28])<<8 | int(data[29])<<16
		return w + 1, h + 1
	default:
		return 0, 0
	}
}

// fileSizeOrZero returns the size of path, or 0 when it cannot be stat'ed.
func fileSizeOrZero(path string) int64 {
	if info, err := os.Stat(path); err == nil {
		return info.Size()
	}
	return 0
}
