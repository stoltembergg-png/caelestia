package whatsapp

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// Media kinds exposed over IPC. They are part of the contract (docs/IPC.md §6).
const (
	mediaKindImage    = "image"
	mediaKindVideo    = "video"
	mediaKindAudio    = "audio"
	mediaKindDocument = "document"
	mediaKindSticker  = "sticker"
)

// errNoDownloadProto means a media row exists but its download descriptor was
// never persisted (e.g. an old row). It maps to the stable no_media code.
var errNoDownloadProto = errors.New("whatsapp: media download descriptor missing")

// mediaDescriptor returns the coarse kind plus the download-relevant fields and
// the protobuf sub-message of a media message. It returns a nil sub-message for
// non-media messages.
func mediaDescriptor(m *waE2E.Message) (kind, mime string, size uint64, width, height uint32, filename string, sub whatsmeow.DownloadableMessage) {
	if m == nil {
		return "", "", 0, 0, 0, "", nil
	}
	switch {
	case m.GetImageMessage() != nil:
		v := m.GetImageMessage()
		return mediaKindImage, mimeOrDefault(v.GetMimetype(), "image/jpeg"), v.GetFileLength(), v.GetWidth(), v.GetHeight(), "", v
	case m.GetVideoMessage() != nil:
		v := m.GetVideoMessage()
		return mediaKindVideo, mimeOrDefault(v.GetMimetype(), "video/mp4"), v.GetFileLength(), v.GetWidth(), v.GetHeight(), "", v
	case m.GetAudioMessage() != nil:
		v := m.GetAudioMessage()
		return mediaKindAudio, mimeOrDefault(v.GetMimetype(), "audio/ogg"), v.GetFileLength(), 0, 0, "", v
	case m.GetDocumentMessage() != nil:
		v := m.GetDocumentMessage()
		return mediaKindDocument, mimeOrDefault(v.GetMimetype(), "application/octet-stream"), v.GetFileLength(), 0, 0, v.GetFileName(), v
	case m.GetStickerMessage() != nil:
		v := m.GetStickerMessage()
		return mediaKindSticker, mimeOrDefault(v.GetMimetype(), "image/webp"), v.GetFileLength(), v.GetWidth(), v.GetHeight(), "", v
	default:
		return "", "", 0, 0, 0, "", nil
	}
}

// extractMedia builds the cae_media row for a media message (bytes excluded; the
// protobuf sub-message with the download keys is stored instead). It returns nil
// for non-media messages or when the sub-message cannot be marshaled.
func extractMedia(messageID string, m *waE2E.Message) *database.Media {
	if messageID == "" {
		return nil
	}
	kind, mime, size, width, height, filename, sub := mediaDescriptor(m)
	if sub == nil {
		return nil
	}
	pm, ok := sub.(proto.Message)
	if !ok {
		return nil
	}
	raw, err := proto.Marshal(pm)
	if err != nil {
		return nil
	}
	return &database.Media{
		ID:        messageID,
		MessageID: messageID,
		Kind:      kind,
		Mime:      mime,
		Size:      int64(size),
		Width:     int(width),
		Height:    int(height),
		Filename:  filename,
		Proto:     raw,
	}
}

// decodeDownloadable reconstructs the whatsmeow download descriptor from the
// stored protobuf bytes. The concrete type must match kind so GetMediaType
// returns the right key derivation.
func decodeDownloadable(kind string, raw []byte) (whatsmeow.DownloadableMessage, error) {
	if len(raw) == 0 {
		return nil, errNoDownloadProto
	}
	switch kind {
	case mediaKindImage:
		v := &waE2E.ImageMessage{}
		if err := proto.Unmarshal(raw, v); err != nil {
			return nil, err
		}
		return v, nil
	case mediaKindVideo:
		v := &waE2E.VideoMessage{}
		if err := proto.Unmarshal(raw, v); err != nil {
			return nil, err
		}
		return v, nil
	case mediaKindAudio:
		v := &waE2E.AudioMessage{}
		if err := proto.Unmarshal(raw, v); err != nil {
			return nil, err
		}
		return v, nil
	case mediaKindDocument:
		v := &waE2E.DocumentMessage{}
		if err := proto.Unmarshal(raw, v); err != nil {
			return nil, err
		}
		return v, nil
	case mediaKindSticker:
		v := &waE2E.StickerMessage{}
		if err := proto.Unmarshal(raw, v); err != nil {
			return nil, err
		}
		return v, nil
	default:
		return nil, fmt.Errorf("whatsapp: unsupported media kind %q", kind)
	}
}

// mediaThumbnail returns the embedded thumbnail bytes of a media message, if
// any. Only image, video and sticker carry one that the contract exposes.
func mediaThumbnail(kind string, raw []byte) []byte {
	if len(raw) == 0 {
		return nil
	}
	switch kind {
	case mediaKindImage:
		v := &waE2E.ImageMessage{}
		if proto.Unmarshal(raw, v) == nil {
			return v.GetJPEGThumbnail()
		}
	case mediaKindVideo:
		v := &waE2E.VideoMessage{}
		if proto.Unmarshal(raw, v) == nil {
			return v.GetJPEGThumbnail()
		}
	case mediaKindSticker:
		v := &waE2E.StickerMessage{}
		if proto.Unmarshal(raw, v) == nil {
			return v.GetPngThumbnail()
		}
	}
	return nil
}

// mediaDirName maps a media kind to its cache subdirectory (docs/IPC.md §3.5).
func mediaDirName(kind string) string {
	switch kind {
	case mediaKindImage:
		return "images"
	case mediaKindVideo:
		return "videos"
	case mediaKindAudio:
		return "audio"
	case mediaKindDocument:
		return "documents"
	case mediaKindSticker:
		return "stickers"
	default:
		return "documents"
	}
}

// mediaExtension returns a safe file extension for a downloaded media file. It
// prefers the document's own name only when the extension is in a small
// whitelist, so a crafted filename can never escape the cache directory.
func mediaExtension(kind, mime, filename string) string {
	if kind == mediaKindDocument {
		if ext := safeExtension(filepath.Ext(filename)); ext != "" {
			return ext
		}
	}
	m := strings.ToLower(strings.TrimSpace(strings.SplitN(mime, ";", 2)[0]))
	switch m {
	case "image/jpeg", "image/jpg":
		return "jpg"
	case "image/png":
		return "png"
	case "image/webp":
		return "webp"
	case "image/gif":
		return "gif"
	case "video/mp4":
		return "mp4"
	case "video/3gpp":
		return "3gp"
	case "video/quicktime":
		return "mov"
	case "audio/ogg", "audio/opus", "audio/ogg; codecs=opus":
		return "ogg"
	case "audio/mpeg":
		return "mp3"
	case "audio/mp4", "audio/aac":
		return "m4a"
	case "audio/wav", "audio/x-wav":
		return "wav"
	case "application/pdf":
		return "pdf"
	}
	switch kind {
	case mediaKindImage:
		return "jpg"
	case mediaKindVideo:
		return "mp4"
	case mediaKindAudio:
		return "ogg"
	case mediaKindSticker:
		return "webp"
	default:
		return "bin"
	}
}

// safeExtension accepts a leading-dot extension only when it is a short,
// alphanumeric token; otherwise it returns "". This is a path-traversal guard.
func safeExtension(ext string) string {
	ext = strings.TrimPrefix(strings.ToLower(ext), ".")
	if ext == "" || len(ext) > 5 {
		return ""
	}
	for _, r := range ext {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			return ""
		}
	}
	return ext
}

// fileSHA256Hex hashes the file at path and returns its lowercase hex digest.
func fileSHA256Hex(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// mimeOrDefault returns mime when set, else fallback.
func mimeOrDefault(mime, fallback string) string {
	if strings.TrimSpace(mime) == "" {
		return fallback
	}
	return mime
}

// validSHA256Hex reports whether s is a 64-character lowercase hex digest, the
// only shape accepted as a cache file name.
func validSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

// sha256HexBytes returns the lowercase hex SHA-256 of b.
func sha256HexBytes(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// mediaProtoSHA256 returns the plaintext SHA-256 (hex) stored in a media
// protobuf, when present and well-formed. It is used to name the thumbnail file
// exactly like the downloaded media, so both forms share one cache entry.
func mediaProtoSHA256(kind string, raw []byte) string {
	sub, err := decodeDownloadable(kind, raw)
	if err != nil {
		return ""
	}
	sum := sub.GetFileSHA256()
	if len(sum) != 32 {
		return ""
	}
	return hex.EncodeToString(sum)
}

// writeThumbFile stores thumbnail bytes as <sha>.jpg under thumbDir, atomically
// and owner-only. It is shared by the download path, the send path and the
// embedded-thumbnail persistence/backfill so every thumbnail uses one naming
// scheme.
func writeThumbFile(thumbDir, sha string, data []byte) (string, error) {
	if thumbDir == "" || sha == "" || len(data) == 0 {
		return "", errors.New("whatsapp: invalid thumbnail target")
	}
	if err := os.MkdirAll(thumbDir, database.DirPerm); err != nil {
		return "", err
	}
	final := filepath.Join(thumbDir, sha+".jpg")
	if !pathWithin(thumbDir, final) {
		return "", errors.New("whatsapp: thumbnail path escapes data dir")
	}
	tmp, err := os.CreateTemp(thumbDir, ".thumb-*")
	if err != nil {
		return "", err
	}
	tmpPath := tmp.Name()
	ok := false
	defer func() {
		if !ok {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(data); err != nil {
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmpPath, final); err != nil {
		return "", err
	}
	if err := os.Chmod(final, database.FilePerm); err != nil {
		return "", err
	}
	ok = true
	return final, nil
}
