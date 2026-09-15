package whatsapp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// Stable method error codes (see docs/IPC.md). They are part of the contract.
const (
	// CodeNotPaired means there is no paired session, so the operation cannot
	// run.
	CodeNotPaired = "not_paired"
	// CodeNotFound means the requested chat/message/contact does not exist.
	CodeNotFound = "not_found"
	// CodeInvalidRequest means the params are missing or malformed.
	CodeInvalidRequest = "invalid_request"
	// CodeSendFailed means the outbound WhatsApp operation failed.
	CodeSendFailed = "send_failed"
	// CodeNoMedia means the message exists but carries no downloadable media.
	CodeNoMedia = "no_media"
	// CodeDownloadFailed means fetching media/avatar bytes failed.
	CodeDownloadFailed = "download_failed"
	// CodeFileNotFound means the media.send source path does not exist.
	CodeFileNotFound = "file_not_found"
	// CodeFileTooLarge means the media.send source exceeds the size limit.
	CodeFileTooLarge = "file_too_large"
	// CodeUnsupportedType means the media.send source is not a supported file.
	CodeUnsupportedType = "unsupported_type"
	// CodeUploadFailed means uploading the media to WhatsApp failed.
	CodeUploadFailed = "upload_failed"
)

// sendTimeout bounds a single outbound WhatsApp operation.
const sendTimeout = 30 * time.Second

// mediaDownloadTimeout bounds a single media download (streaming to disk).
const mediaDownloadTimeout = 2 * time.Minute

// mediaUploadTimeout bounds the upload + encryption pass of one outbound media
// file. Large documents can take a while on a slow link.
const mediaUploadTimeout = 10 * time.Minute

// maxMediaSendBytes is the hard limit for an outbound media file (100 MB).
const maxMediaSendBytes = 100 << 20

// Methods implements the chats/messages/contacts/media/avatar IPC methods on
// top of the repository and the whatsmeow service. It is registered by main.go.
type Methods struct {
	svc    *Service
	repo   *database.Repo
	logger *slog.Logger

	// Data/cache roots. Every path handed back over IPC is built by joining a
	// hashed file name to one of these, never from client input.
	dataDir  string
	cacheDir string
	thumbDir string

	avatars *avatarStore
}

// NewMethods builds the method set. svc, repo and dataDir must be non-nil.
func NewMethods(svc *Service, repo *database.Repo, dataDir string, logger *slog.Logger) *Methods {
	if logger == nil {
		logger = slog.Default()
	}
	m := &Methods{
		svc:      svc,
		repo:     repo,
		logger:   logger,
		dataDir:  dataDir,
		cacheDir: filepath.Join(dataDir, "cache"),
		thumbDir: filepath.Join(dataDir, "thumbnails"),
	}
	m.avatars = newAvatarStore(repo, svc, logger, filepath.Join(m.cacheDir, "avatars"))
	return m
}

// Register installs every method on the IPC server.
func (m *Methods) Register(s *ipc.Server) {
	s.Register("chats.list", wrap(m.ChatsList))
	s.Register("chat.open", wrap(m.ChatOpen))
	s.Register("chat.messages", wrap(m.ChatMessages))
	s.Register("message.send", wrap(m.MessageSend))
	s.Register("message.reply", wrap(m.MessageReply))
	s.Register("message.read", wrap(m.MessageRead))
	s.Register("message.react", wrap(m.MessageReact))
	s.Register("contacts.search", wrap(m.ContactsSearch))
	s.Register("avatars.download", wrap(m.AvatarsDownload))
	s.Register("media.download", wrap(m.MediaDownload))
	s.Register("media.send", wrap(m.MediaSend))
}

// methodFunc is the testable shape of a handler (without the *ipc.Client).
type methodFunc func(ctx context.Context, params json.RawMessage) (any, *ipc.Error)

// wrap adapts a methodFunc to the ipc.Handler signature.
func wrap(fn methodFunc) ipc.Handler {
	return func(ctx context.Context, _ *ipc.Client, params json.RawMessage) (any, *ipc.Error) {
		return fn(ctx, params)
	}
}

// jsonInt64 accepts an integer encoded either as a JSON number or as a decimal
// string (the latter is how 64-bit values travel on the wire).
type jsonInt64 int64

func (v *jsonInt64) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "" || s == "null" {
		*v = 0
		return nil
	}
	s = strings.Trim(s, `"`)
	if s == "" {
		*v = 0
		return nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid integer %q", s)
	}
	*v = jsonInt64(n)
	return nil
}

// decodeParams unmarshals optional params. Absent/null params leave dst zeroed.
func decodeParams(raw json.RawMessage, dst any) *ipc.Error {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return nil
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return &ipc.Error{Code: CodeInvalidRequest, Message: "invalid params: " + err.Error()}
	}
	return nil
}

func invalidRequest(msg string) *ipc.Error {
	return &ipc.Error{Code: CodeInvalidRequest, Message: msg}
}

func notFound(msg string) *ipc.Error {
	return &ipc.Error{Code: CodeNotFound, Message: msg}
}

func internalError(err error) *ipc.Error {
	return &ipc.Error{Code: ipc.ErrorInternal, Message: err.Error()}
}

// requirePaired rejects operations when no device has ever been paired. A
// paired-but-offline daemon still allows reads from the local database.
func (m *Methods) requirePaired() *ipc.Error {
	st := m.svc.AuthStatus()
	if st.JID == "" && !st.LoggedIn {
		return &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}
	return nil
}

// --- chats.list ---

type chatsListParams struct {
	Limit jsonInt64 `json:"limit"`
}

// ChatsList returns the most recent chats.
func (m *Methods) ChatsList(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p chatsListParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	chats, err := m.repo.ListChats(ctx, int(p.Limit))
	if err != nil {
		return nil, internalError(err)
	}
	out := make([]map[string]any, 0, len(chats))
	for i := range chats {
		c := chats[i]
		// Lazy backfill: a chat whose name was never known (or was stored as a
		// raw @lid by an older build) is resolved on read, persisted and then
		// returned. The resolver's short-lived cache keeps repeated calls cheap.
		c.Name = m.backfillChatName(ctx, &c)
		// Avatar backfill is also lazy, but never blocks: a cached path is
		// returned immediately and a miss schedules a background fetch that
		// emits chat.updated when it completes.
		avatar := m.avatars.backfill(ctx, c.JID)
		out = append(out, chatPayload(c, avatar))
	}
	return out, nil
}

// backfillChatName resolves a missing chat name, persists it and emits
// chat.updated when it changed. It returns the display name to use (the
// resolved name, the fallback when only a fallback exists, or the stored name
// when it is already valid). It never persists a fallback.
func (m *Methods) backfillChatName(ctx context.Context, c *database.Chat) string {
	if c == nil {
		return ""
	}
	if chatNameResolved(c.Name, c.JID) {
		return c.Name
	}
	name, resolved := m.svc.nameResolver().Resolve(ctx, m.repo, c.JID, "")
	if !resolved {
		// Display the fallback (formatted PN) but leave cae_chats.name empty so
		// a later contact/push name can still be picked up.
		if name != "" {
			return name
		}
		return c.JID
	}
	if name == "" || name == c.Name {
		return firstNonEmpty(c.Name, name)
	}
	if err := m.repo.UpsertChat(ctx, database.Chat{JID: c.JID, Kind: c.Kind, Name: name}); err != nil {
		m.logger.Warn("whatsapp: backfill chat name failed",
			slog.String("jid", logging.RedactJID(c.JID)),
			slog.String("error", err.Error()))
		return firstNonEmpty(c.Name, name)
	}
	c.Name = name
	m.svc.emit(EventChatUpdated, chatUpdatedData(c))
	return name
}

// chatNameResolved reports whether name is a real display name rather than a
// missing value or a raw identifier (jid or @lid).
func chatNameResolved(name, jid string) bool {
	if name == "" || name == jid {
		return false
	}
	if strings.HasSuffix(name, "@"+types.HiddenUserServer) {
		return false
	}
	return true
}

// --- chat.open ---

type chatOpenParams struct {
	JID string `json:"jid"`
}

// ChatOpen returns the metadata of a single chat.
func (m *Methods) ChatOpen(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p chatOpenParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	if p.JID == "" {
		return nil, invalidRequest("jid is required")
	}
	c, err := m.repo.GetChat(ctx, p.JID)
	if err != nil {
		if errors.Is(err, database.ErrNotFound) {
			return nil, notFound("chat not found")
		}
		return nil, internalError(err)
	}
	c.Name = m.backfillChatName(ctx, c)
	return chatPayload(*c, m.avatars.backfill(ctx, c.JID)), nil
}

// --- chat.messages ---

type chatMessagesParams struct {
	JID    string    `json:"jid"`
	Limit  jsonInt64 `json:"limit"`
	Before jsonInt64 `json:"before"`
}

// ChatMessages returns a page of a chat's messages, newest first.
func (m *Methods) ChatMessages(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p chatMessagesParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	if p.JID == "" {
		return nil, invalidRequest("jid is required")
	}
	msgs, err := m.repo.ListMessages(ctx, p.JID, int(p.Limit), int64(p.Before))
	if err != nil {
		return nil, internalError(err)
	}
	ids := make([]string, 0, len(msgs))
	for i := range msgs {
		ids = append(ids, msgs[i].ID)
	}
	// Two batched lookups instead of one query per message: media metadata and
	// current reactions. Neither carries bytes.
	media, err := m.repo.MediaForMessages(ctx, ids)
	if err != nil {
		return nil, internalError(err)
	}
	reactions, err := m.repo.ListReactionsForMessages(ctx, ids)
	if err != nil {
		return nil, internalError(err)
	}
	out := make([]map[string]any, 0, len(msgs))
	for _, msg := range msgs {
		var md *database.Media
		if row, ok := media[msg.ID]; ok {
			md = &row
		}
		out = append(out, messagePayload(msg, md, reactions[msg.ID]))
	}
	return out, nil
}

// --- message.send / message.reply ---

type messageSendParams struct {
	JID  string `json:"jid"`
	Text string `json:"text"`
}

type messageReplyParams struct {
	JID  string `json:"jid"`
	ID   string `json:"id"`
	Text string `json:"text"`
}

// MessageSend sends a plain text message.
func (m *Methods) MessageSend(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p messageSendParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	return m.sendText(ctx, p.JID, p.Text, "")
}

// MessageReply sends a text message quoting another message.
func (m *Methods) MessageReply(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p messageReplyParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.ID) == "" {
		return nil, invalidRequest("id is required")
	}
	return m.sendText(ctx, p.JID, p.Text, p.ID)
}

func (m *Methods) sendText(ctx context.Context, jidStr, text, quotedID string) (any, *ipc.Error) {
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, invalidRequest("text is required")
	}
	jid, err := parseJID(jidStr)
	if err != nil {
		return nil, invalidRequest("invalid jid: " + err.Error())
	}
	c := m.svc.fullClient()
	if c == nil {
		return nil, &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}

	quotedSender := jid.String()
	if quotedID != "" {
		if ref, err := m.repo.GetMessage(ctx, quotedID); err == nil && ref.SenderJID != "" {
			quotedSender = ref.SenderJID
		}
	}
	message := buildTextMessage(text, quotedID, quotedSender)

	sendCtx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	resp, err := c.SendMessage(sendCtx, jid, message)
	if err != nil {
		m.logger.Warn("whatsapp: send failed",
			slog.String("chat", logging.RedactJID(jid.String())),
			slog.String("error", err.Error()))
		return nil, &ipc.Error{Code: CodeSendFailed, Message: "whatsapp: send failed"}
	}

	// Store our own copy immediately so the chat list updates without waiting
	// for the server echo (which is also persisted, idempotently, later).
	m.storeOutgoing(ctx, jid, string(resp.ID), text, quotedID, resp.Timestamp.UnixMilli())
	return map[string]any{
		"id":        string(resp.ID),
		"timestamp": ipc.StringTimestamp(resp.Timestamp.UnixMilli()),
	}, nil
}

// storeOutgoing best-effort persists a locally sent message.
func (m *Methods) storeOutgoing(ctx context.Context, jid types.JID, id, text, quotedID string, ts int64) {
	chatJID := jid.String()
	_ = m.repo.UpsertChat(ctx, database.Chat{
		JID:  chatJID,
		Kind: kindForJID(jid),
		Name: m.chatName(ctx, chatJID),
	})
	_, _ = m.repo.InsertMessage(ctx, database.Message{
		ID:        id,
		ChatJID:   chatJID,
		SenderJID: m.svc.AuthStatus().JID,
		FromMe:    true,
		Timestamp: ts,
		Type:      "text",
		Text:      text,
		QuotedID:  quotedID,
		Status:    "sent",
	})
	_ = m.repo.UpdateChatLastMessage(ctx, chatJID, id, ts, text)
}

// buildTextMessage builds a plain text or quoted-reply message.
func buildTextMessage(text, quotedID, quotedSender string) *waE2E.Message {
	if quotedID == "" {
		return &waE2E.Message{Conversation: proto.String(text)}
	}
	return &waE2E.Message{
		ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String(text),
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:    proto.String(quotedID),
				Participant: proto.String(quotedSender),
			},
		},
	}
}

// --- message.read ---

type messageReadParams struct {
	JID string `json:"jid"`
}

// MessageRead marks the pending incoming messages of a chat as read.
func (m *Methods) MessageRead(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p messageReadParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	jid, err := parseJID(p.JID)
	if err != nil {
		return nil, invalidRequest("invalid jid: " + err.Error())
	}
	c := m.svc.fullClient()
	if c == nil {
		return nil, &ipc.Error{Code: CodeNotPaired, Message: "whatsapp: no paired device"}
	}

	refs, err := m.repo.PendingIncomingMessages(ctx, jid.String())
	if err != nil {
		return nil, internalError(err)
	}
	if len(refs) == 0 {
		return map[string]any{"read": 0}, nil
	}

	bySender := make(map[string][]types.MessageID)
	allIDs := make([]string, 0, len(refs))
	for _, ref := range refs {
		sender := ref.SenderJID
		if sender == "" {
			sender = jid.String()
		}
		bySender[sender] = append(bySender[sender], types.MessageID(ref.ID))
		allIDs = append(allIDs, ref.ID)
	}

	readCtx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	for sender, ids := range bySender {
		senderJID, perr := types.ParseJID(sender)
		if perr != nil {
			senderJID = jid
		}
		if err := c.MarkRead(readCtx, ids, time.Now(), jid, senderJID); err != nil {
			m.logger.Warn("whatsapp: mark read failed",
				slog.String("chat", logging.RedactJID(jid.String())),
				slog.String("error", err.Error()))
			return nil, &ipc.Error{Code: CodeSendFailed, Message: "whatsapp: mark read failed"}
		}
	}

	_ = m.repo.SetMessagesStatus(ctx, allIDs, "read")
	_ = m.repo.MarkChatRead(ctx, jid.String())
	return map[string]any{"read": len(allIDs)}, nil
}

// --- contacts.search ---

type contactsSearchParams struct {
	Query string    `json:"query"`
	Limit jsonInt64 `json:"limit"`
}

// ContactsSearch does a LIKE search over locally known contacts.
func (m *Methods) ContactsSearch(ctx context.Context, params json.RawMessage) (any, *ipc.Error) {
	var p contactsSearchParams
	if err := decodeParams(params, &p); err != nil {
		return nil, err
	}
	if err := m.requirePaired(); err != nil {
		return nil, err
	}
	contacts, err := m.repo.SearchContacts(ctx, p.Query, int(p.Limit))
	if err != nil {
		return nil, internalError(err)
	}
	out := make([]map[string]any, 0, len(contacts))
	for _, c := range contacts {
		out = append(out, contactPayload(c))
	}
	return out, nil
}

// --- payload helpers ---

func chatPayload(c database.Chat, avatar string) map[string]any {
	name := c.Name
	if name == "" {
		name = c.JID
	}
	out := map[string]any{
		"jid":         c.JID,
		"kind":        c.Kind,
		"name":        name,
		"lastMessage": c.LastPreview,
		"unread":      c.UnreadCount,
		"avatar":      nil,
	}
	if avatar != "" {
		out["avatar"] = avatar
	}
	if c.LastMessageTS > 0 {
		out["timestamp"] = ipc.StringTimestamp(c.LastMessageTS)
	} else {
		out["timestamp"] = ""
	}
	if c.LastMessageID != "" {
		out["lastMessageId"] = c.LastMessageID
	}
	return out
}

func messagePayload(m database.Message, media *database.Media, reactions []database.Reaction) map[string]any {
	out := map[string]any{
		"id":        m.ID,
		"chat":      m.ChatJID,
		"sender":    m.SenderJID,
		"fromMe":    m.FromMe,
		"timestamp": ipc.StringTimestamp(m.Timestamp),
		"type":      m.Type,
		"text":      m.Text,
		"quotedId":  m.QuotedID,
		"edited":    m.Edited,
		"deleted":   m.Deleted,
		"status":    m.Status,
		"reactions": reactionPayloads(reactions),
	}
	if media != nil {
		out["media"] = mediaPayload(media)
	}
	return out
}

// mediaPayload builds the IPC view of a media row. It never includes bytes: only
// metadata plus the on-disk paths (null thumb when not generated).
func mediaPayload(md *database.Media) map[string]any {
	if md == nil {
		return nil
	}
	var thumb any
	if md.ThumbPath != "" && fileExists(md.ThumbPath) {
		thumb = md.ThumbPath
	}
	return map[string]any{
		"kind":       md.Kind,
		"mime":       md.Mime,
		"size":       md.Size,
		"width":      md.Width,
		"height":     md.Height,
		"downloaded": md.Status == "done" && fileExists(md.Path),
		"thumb":      thumb,
	}
}

// reactionPayloads renders the current reactions of a message as
// [{"sender","emoji","from_me"}]. It always returns a non-nil slice.
func reactionPayloads(reactions []database.Reaction) []map[string]any {
	out := make([]map[string]any, 0, len(reactions))
	for _, r := range reactions {
		out = append(out, map[string]any{
			"sender":  r.SenderJID,
			"emoji":   r.Emoji,
			"from_me": r.FromMe,
		})
	}
	return out
}

func contactPayload(c database.Contact) map[string]any {
	name := c.FullName
	if name == "" {
		name = c.FirstName
	}
	if name == "" {
		name = c.PushName
	}
	if name == "" {
		name = c.JID
	}
	return map[string]any{
		"jid":       c.JID,
		"name":      name,
		"firstName": c.FirstName,
		"fullName":  c.FullName,
		"pushName":  c.PushName,
	}
}

func kindForJID(jid types.JID) string {
	if jid.Server == types.GroupServer {
		return "group"
	}
	return "dm"
}

// parseJID validates that s looks like a JID before handing it to whatsmeow,
// which is lenient about strings without a server part.
func parseJID(s string) (types.JID, error) {
	if !strings.Contains(s, "@") {
		return types.EmptyJID, errors.New("missing server part")
	}
	return types.ParseJID(s)
}

// chatName returns a resolved display name for a chat, or "" when only a
// fallback is available (storeOutgoing must not persist a fallback as a name).
func (m *Methods) chatName(ctx context.Context, chatJID string) string {
	c, err := m.repo.GetChat(ctx, chatJID)
	if err == nil && chatNameResolved(c.Name, c.JID) {
		return c.Name
	}
	name, resolved := m.svc.nameResolver().Resolve(ctx, m.repo, chatJID, "")
	if !resolved {
		return ""
	}
	return name
}
