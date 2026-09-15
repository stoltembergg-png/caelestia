package whatsapp

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// --- media.download ---

type mediaDownloadParams struct {
	Chat string `json:"chat"`
	ID   string `json:"id"`
}

// MediaDownload streams a message's media attachment to the on-disk cache and
// returns its path plus metadata. It never returns bytes over IPC. A previously
// downloaded file is served from cache.
func (m *Methods) MediaDownload(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p mediaDownloadParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Chat) == "" || strings.TrimSpace(p.ID) == "" {
		return nil, invalidRequest("chat and id are required")
	}

	msg, err := m.repo.GetMessage(ctx, p.ID)
	if err != nil {
		if errors.Is(err, database.ErrNotFound) {
			return nil, notFound("message not found")
		}
		return nil, internalError(err)
	}
	if msg.ChatJID != p.Chat {
		return nil, notFound("message not found in chat")
	}

	media, err := m.repo.GetMedia(ctx, p.ID)
	if err != nil {
		if errors.Is(err, database.ErrNotFound) {
			return nil, &ipc.Error{Code: CodeNoMedia, Message: "whatsapp: message has no media"}
		}
		return nil, internalError(err)
	}

	// Cache hit: only paths confined to the data-dir are ever returned.
	if media.Status == "done" && fileExists(media.Path) && pathWithin(m.dataDir, media.Path) {
		if media.ThumbPath != "" && !fileExists(media.ThumbPath) {
			media.ThumbPath = ""
		}
		return mediaDownloadResult(media, true), nil
	}

	c := m.svc.fullClient()
	if c == nil {
		return nil, &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}
	sub, derr := decodeDownloadable(media.Kind, media.Proto)
	if derr != nil {
		return nil, &ipc.Error{Code: CodeNoMedia, Message: "whatsapp: media is not downloadable"}
	}

	dir := filepath.Join(m.cacheDir, mediaDirName(media.Kind))
	if err := os.MkdirAll(dir, database.DirPerm); err != nil {
		return nil, internalError(err)
	}
	tmp, err := os.CreateTemp(dir, ".media-*")
	if err != nil {
		return nil, internalError(err)
	}
	tmpPath := tmp.Name()
	done := false
	defer func() {
		if !done {
			_ = tmp.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	dctx, cancel := context.WithTimeout(ctx, mediaDownloadTimeout)
	defer cancel()
	if err := c.DownloadToFile(dctx, sub, tmp); err != nil {
		m.logger.Warn("whatsapp: media download failed",
			slog.String("chat", logging.RedactJID(p.Chat)),
			slog.String("error", err.Error()))
		return nil, &ipc.Error{Code: CodeDownloadFailed, Message: "whatsapp: media download failed"}
	}
	if err := tmp.Close(); err != nil {
		return nil, internalError(err)
	}

	sha := strings.ToLower(strings.TrimSpace(media.SHA256))
	if !validSHA256Hex(sha) {
		sha, err = fileSHA256Hex(tmpPath)
		if err != nil {
			return nil, internalError(err)
		}
	}
	ext := mediaExtension(media.Kind, media.Mime, media.Filename)
	final := filepath.Join(dir, sha+"."+ext)
	if !pathWithin(dir, final) {
		return nil, internalError(errors.New("whatsapp: media path escapes cache dir"))
	}
	if err := os.Rename(tmpPath, final); err != nil {
		return nil, internalError(err)
	}
	if err := os.Chmod(final, database.FilePerm); err != nil {
		return nil, internalError(err)
	}
	done = true

	thumbPath := ""
	if tb := mediaThumbnail(media.Kind, media.Proto); len(tb) > 0 {
		if tp, terr := m.writeThumbnail(sha, tb); terr == nil {
			thumbPath = tp
		} else {
			m.logger.Warn("whatsapp: thumbnail write failed", slog.String("error", terr.Error()))
		}
	}

	media.Path = final
	media.SHA256 = sha
	media.Status = "done"
	media.ThumbPath = thumbPath
	if err := m.repo.MarkMediaDownloaded(ctx, p.ID, final, sha, thumbPath); err != nil {
		m.logger.Warn("whatsapp: persist media failed",
			slog.String("chat", logging.RedactJID(p.Chat)), slog.String("error", err.Error()))
	}
	return mediaDownloadResult(media, false), nil
}

// mediaDownloadResult renders the IPC payload of a downloaded media row.
func mediaDownloadResult(md *database.Media, cached bool) map[string]any {
	var thumb any
	if md.ThumbPath != "" && fileExists(md.ThumbPath) {
		thumb = md.ThumbPath
	}
	return map[string]any{
		"kind":   md.Kind,
		"mime":   md.Mime,
		"size":   md.Size,
		"width":  md.Width,
		"height": md.Height,
		"path":   md.Path,
		"thumb":  thumb,
		"cached": cached,
	}
}

// writeThumbnail stores embedded thumbnail bytes as <sha>.jpg under the
// top-level thumbnails/ directory, atomically and owner-only.
func (m *Methods) writeThumbnail(sha string, data []byte) (string, error) {
	return writeThumbFile(m.thumbDir, sha, data)
}

// --- message.react ---

type messageReactParams struct {
	Chat  string `json:"chat"`
	ID    string `json:"id"`
	Emoji string `json:"emoji"`
}

// MessageReact sends a reaction to a message. An empty emoji removes the
// caller's current reaction. It is persisted and announced with a
// message.updated event carrying the reaction.
func (m *Methods) MessageReact(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p messageReactParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	chat := strings.TrimSpace(p.Chat)
	id := strings.TrimSpace(p.ID)
	if chat == "" || id == "" {
		return nil, invalidRequest("chat and id are required")
	}
	jid, err := parseJID(chat)
	if err != nil {
		return nil, invalidRequest("invalid jid: " + err.Error())
	}
	ref, err := m.repo.GetMessage(ctx, id)
	if err != nil {
		if errors.Is(err, database.ErrNotFound) {
			return nil, notFound("message not found")
		}
		return nil, internalError(err)
	}
	if ref.ChatJID != chat {
		return nil, notFound("message not found in chat")
	}

	c := m.svc.fullClient()
	if c == nil {
		return nil, &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}
	senderStr := ref.SenderJID
	if senderStr == "" {
		senderStr = chat
	}
	sender, perr := types.ParseJID(senderStr)
	if perr != nil {
		sender = jid
	}

	sendCtx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	if _, err := c.SendMessage(sendCtx, jid, c.BuildReaction(jid, sender, types.MessageID(id), p.Emoji)); err != nil {
		m.logger.Warn("whatsapp: react failed",
			slog.String("chat", logging.RedactJID(chat)),
			slog.String("error", err.Error()))
		return nil, &ipc.Error{Code: CodeSendFailed, Message: "whatsapp: react failed"}
	}

	selfJID := m.svc.AuthStatus().JID
	if selfJID == "" {
		selfJID = senderStr
	}
	if err := m.repo.UpsertReaction(ctx, database.Reaction{
		MessageID: id,
		ChatJID:   chat,
		SenderJID: selfJID,
		Emoji:     p.Emoji,
		FromMe:    true,
		Timestamp: time.Now().UnixMilli(),
	}); err != nil {
		m.logger.Warn("whatsapp: persist reaction failed",
			slog.String("chat", logging.RedactJID(chat)), slog.String("error", err.Error()))
	}
	m.svc.emit(EventMessageUpdated, map[string]any{
		"chat": chat,
		"id":   id,
		"reaction": map[string]any{
			"sender": selfJID,
			"emoji":  p.Emoji,
		},
	})
	return map[string]any{"ok": true}, nil
}
