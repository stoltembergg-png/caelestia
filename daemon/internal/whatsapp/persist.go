package whatsapp

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// fullClient is the extended whatsmeow surface used by the persistence worker
// and the IPC methods. *realClient satisfies it (it embeds *whatsmeow.Client);
// tests provide fakes.
type fullClient interface {
	waClient
	ParseWebMessage(chatJID types.JID, webMsg *waWeb.WebMessageInfo) (*events.Message, error)
	SendMessage(ctx context.Context, to types.JID, message *waE2E.Message, extra ...whatsmeow.SendRequestExtra) (whatsmeow.SendResponse, error)
	MarkRead(ctx context.Context, ids []types.MessageID, timestamp time.Time, chat, sender types.JID, receiptTypeExtra ...types.ReceiptType) error
}

// fullClient returns the current client as a fullClient, or nil when the
// underlying implementation only provides the base waClient surface.
func (s *Service) fullClient() fullClient {
	c := s.currentClient()
	if c == nil {
		return nil
	}
	fc, _ := c.(fullClient)
	return fc
}

// Persister consumes Message/Receipt/HistorySync/Contact/GroupInfo events and
// writes them to the cae_* tables. It runs a single worker goroutine so writes
// are serialized and the whatsmeow handler is never blocked: the handler only
// classifies and enqueues.
type Persister struct {
	svc    *Service
	repo   *database.Repo
	logger *slog.Logger

	inbox chan any
	done  chan struct{}
	wg    sync.WaitGroup

	closeOnce sync.Once

	// parseWebMessage is a seam over the client so history sync can be tested
	// with a fake parser (the real client requires a live session).
	parseWebMessage func(types.JID, *waWeb.WebMessageInfo) (*events.Message, error)
}

// EnablePersistence attaches a persistence pipeline to the service and starts
// its worker. The Persister is registered on the current client and stored on
// the Service, so attachHandlersLocked re-registers it on every client built
// afterwards (e.g. after a logout + re-pair). Callers must Close the returned
// Persister before closing the DB.
func (s *Service) EnablePersistence(repo *database.Repo) *Persister {
	if repo == nil {
		panic("whatsapp: EnablePersistence with nil repo")
	}
	p := &Persister{
		svc:    s,
		repo:   repo,
		logger: s.logger,
		inbox:  make(chan any, eventBufferSize*4),
		done:   make(chan struct{}),
	}
	p.parseWebMessage = func(chatJID types.JID, wm *waWeb.WebMessageInfo) (*events.Message, error) {
		c := s.fullClient()
		if c == nil {
			return nil, errors.New("whatsapp: client unavailable")
		}
		return c.ParseWebMessage(chatJID, wm)
	}

	// Publish the persister and register it on the current client under the
	// same lock the rebuild path uses: a concurrent rebuild then either sees
	// the persister and attaches it to the new client, or saw a nil persister
	// and this call attaches it to the client the rebuild has just installed.
	s.mu.Lock()
	s.persister = p
	if s.client != nil {
		s.client.AddEventHandler(p.handleEvent)
	}
	s.mu.Unlock()

	p.wg.Add(1)
	go p.run()
	return p
}

// Close stops the worker. It does not close the shared database.
func (p *Persister) Close() {
	if p == nil {
		return
	}
	p.closeOnce.Do(func() {
		close(p.done)
		p.wg.Wait()
	})
}

// handleEvent is the fast path: it drops everything irrelevant and enqueues the
// persistent event types without doing I/O.
func (p *Persister) handleEvent(evt any) {
	switch evt.(type) {
	case *events.Message, *events.Receipt, *events.HistorySync, *events.Contact, *events.GroupInfo:
	default:
		return
	}
	select {
	case p.inbox <- evt:
	case <-p.done:
	}
}

func (p *Persister) run() {
	defer p.wg.Done()
	for {
		select {
		case <-p.done:
			// Shutdown: whatever was already queued must still be written
			// before the worker exits, otherwise events accepted during the
			// handler's lifetime are silently dropped.
			p.drain()
			return
		case evt := <-p.inbox:
			p.process(evt)
		}
	}
}

// drain processes every event already buffered in the inbox and returns as
// soon as the inbox is momentarily empty. It runs on shutdown so events the
// handler already accepted are written instead of being dropped.
func (p *Persister) drain() {
	for {
		select {
		case evt := <-p.inbox:
			p.process(evt)
		default:
			return
		}
	}
}

// process persists one event, logging (without secrets) on failure.
func (p *Persister) process(evt any) {
	ctx := p.svc.ctx
	switch e := evt.(type) {
	case *events.Message:
		if err := p.persistMessage(ctx, e); err != nil {
			p.logger.Warn("whatsapp: persist message failed",
				slog.String("chat", logging.RedactJID(e.Info.Chat.String())),
				slog.String("error", err.Error()))
		}
	case *events.Receipt:
		if err := p.persistReceipt(ctx, e); err != nil {
			p.logger.Warn("whatsapp: persist receipt failed",
				slog.String("chat", logging.RedactJID(e.Chat.String())),
				slog.String("error", err.Error()))
		}
	case *events.HistorySync:
		if err := p.persistHistory(ctx, e); err != nil {
			p.logger.Warn("whatsapp: persist history sync failed",
				slog.String("error", err.Error()))
		}
	case *events.Contact:
		if err := p.persistContact(ctx, e); err != nil {
			p.logger.Warn("whatsapp: persist contact failed", slog.String("error", err.Error()))
		}
	case *events.GroupInfo:
		if err := p.persistGroup(ctx, e); err != nil {
			p.logger.Warn("whatsapp: persist group failed", slog.String("error", err.Error()))
		}
	}
}

// persistMessage stores one incoming/outgoing message and updates the chat
// bookkeeping. It is idempotent: duplicate MessageIDs are ignored and do not
// bump the unread counter.
func (p *Persister) persistMessage(ctx context.Context, m *events.Message) error {
	return p.persistMessageWithRepo(ctx, p.repo, m)
}

// persistMessageWithRepo is persistMessage bound to an explicit repository so
// history sync can run a whole conversation inside one transaction.
func (p *Persister) persistMessageWithRepo(ctx context.Context, repo *database.Repo, m *events.Message) error {
	if m == nil || m.Info.ID == "" || m.Info.Chat.IsEmpty() {
		return nil
	}

	// Reactions carry no message content. Store only the reaction metadata:
	// they must never create a cae_messages row nor touch last_message,
	// preview or the unread counter (see docs/IPC.md §6).
	if rm := m.Message.GetReactionMessage(); rm != nil {
		return p.persistReaction(ctx, repo, m, rm)
	}

	// Revocations and edits mutate an existing message instead of inserting.
	// Every other protocol message (receipts, ephemeral settings, history sync
	// notifications, key shares, ...) is not user-visible and is ignored
	// entirely: no type=protocol row, no unread bump.
	if pm := m.Message.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			if id := pm.GetKey().GetID(); id != "" {
				return repo.SetMessageDeleted(ctx, id)
			}
			return nil
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if id := pm.GetKey().GetID(); id != "" {
				text, _ := extractText(pm.GetEditedMessage())
				return repo.SetMessageEdited(ctx, id, text)
			}
			return nil
		default:
			return nil
		}
	}

	chatJID := m.Info.Chat.String()
	kind := "dm"
	if m.Info.IsGroup || m.Info.Chat.Server == types.GroupServer {
		kind = "group"
	}

	// Prefer a known group name, then contact name, then push name. An empty
	// name is passed through: UpsertChat never overwrites a known name.
	name := ""
	if kind == "group" {
		if g, err := repo.GetGroup(ctx, chatJID); err == nil {
			name = g.Name
		}
	}
	if name == "" {
		push := ""
		if !m.Info.IsFromMe {
			push = m.Info.PushName
		}
		name = p.resolveName(ctx, repo, chatJID, push)
	}
	if err := repo.UpsertChat(ctx, database.Chat{JID: chatJID, Kind: kind, Name: name}); err != nil {
		return err
	}

	// Contacts: the DM peer, or the group participant. Never derive a contact
	// from our own outgoing message (that would store our own push name under
	// the peer's JID).
	senderJID := m.Info.Sender.String()
	contactJID := chatJID
	if kind == "group" {
		contactJID = senderJID
	}
	if !m.Info.IsFromMe && contactJID != "" && m.Info.PushName != "" {
		if err := repo.UpsertContact(ctx, database.Contact{
			JID:      contactJID,
			PushName: m.Info.PushName,
		}); err != nil {
			return err
		}
	}

	text, mtype := extractText(m.Message)
	msg := database.Message{
		ID:        m.Info.ID,
		ChatJID:   chatJID,
		SenderJID: senderJID,
		FromMe:    m.Info.IsFromMe,
		Timestamp: m.Info.Timestamp.UnixMilli(),
		Type:      mtype,
		Text:      text,
		QuotedID:  extractQuotedID(m.Message),
		Status:    initialStatus(m.Info.IsFromMe),
	}
	inserted, err := repo.InsertMessage(ctx, msg)
	if err != nil {
		return err
	}
	if !inserted {
		return nil
	}

	if err := repo.UpdateChatLastMessage(ctx, chatJID, msg.ID, msg.Timestamp, preview(text, mtype)); err != nil {
		return err
	}
	// Only incoming, newly stored messages increase the unread counter.
	if !m.Info.IsFromMe {
		if err := repo.IncrementUnread(ctx, chatJID); err != nil {
			return err
		}
	}
	return nil
}

// persistReaction stores a reaction as metadata only, in cae_reactions. It
// creates no cae_messages row, so the chat list (last_message/preview) and the
// unread counter are untouched. An empty reaction text removes the reaction.
func (p *Persister) persistReaction(ctx context.Context, repo *database.Repo, m *events.Message, rm *waE2E.ReactionMessage) error {
	target := rm.GetKey().GetID()
	if target == "" {
		return nil
	}
	return repo.UpsertReaction(ctx, database.Reaction{
		MessageID: target,
		ChatJID:   m.Info.Chat.String(),
		SenderJID: m.Info.Sender.String(),
		Emoji:     rm.GetText(),
		FromMe:    m.Info.IsFromMe,
		Timestamp: m.Info.Timestamp.UnixMilli(),
	})
}

// persistReceipt records per-user receipts and advances the message status.
// A read receipt generated by one of our own devices clears the chat unread.
func (p *Persister) persistReceipt(ctx context.Context, r *events.Receipt) error {
	if r == nil || len(r.MessageIDs) == 0 {
		return nil
	}
	chat := r.Chat.String()
	rtype := string(r.Type)
	if rtype == "" {
		// ReceiptTypeDelivered is the empty string in whatsmeow; store a
		// readable value instead.
		rtype = "delivered"
	}

	ids := make([]string, 0, len(r.MessageIDs))
	for _, id := range r.MessageIDs {
		ids = append(ids, string(id))
		if err := p.repo.InsertReceipt(ctx, database.Receipt{
			MessageID: string(id),
			UserJID:   r.Sender.String(),
			Type:      rtype,
			TS:        r.Timestamp.UnixMilli(),
		}); err != nil {
			return err
		}
	}

	switch r.Type {
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		if err := p.repo.SetMessagesStatus(ctx, ids, "read"); err != nil {
			return err
		}
		if r.IsFromMe || r.Type == types.ReceiptTypeReadSelf {
			return p.repo.MarkChatRead(ctx, chat)
		}
	case types.ReceiptTypeDelivered:
		return p.repo.SetMessagesStatus(ctx, ids, "delivered")
	}
	return nil
}

// persistContact upserts contact names from app-state sync. When the event
// carries a PN alternative, both identities are stored.
func (p *Persister) persistContact(ctx context.Context, c *events.Contact) error {
	if c == nil || c.Action == nil || c.JID.IsEmpty() {
		return nil
	}
	contact := database.Contact{
		JID:       c.JID.String(),
		FirstName: c.Action.GetFirstName(),
		FullName:  c.Action.GetFullName(),
	}
	if err := p.repo.UpsertContact(ctx, contact); err != nil {
		return err
	}
	// Store the phone-number identity too, so searches can match either form.
	if pn := c.Action.GetPnJID(); pn != "" && pn != contact.JID {
		if err := p.repo.UpsertContact(ctx, database.Contact{
			JID:       pn,
			FirstName: contact.FirstName,
			FullName:  contact.FullName,
		}); err != nil {
			return err
		}
	}
	return nil
}

// persistGroup upserts group metadata and mirrors the name into the chat row.
func (p *Persister) persistGroup(ctx context.Context, g *events.GroupInfo) error {
	if g == nil || g.JID.IsEmpty() {
		return nil
	}
	group := database.Group{JID: g.JID.String()}
	if g.Name != nil {
		group.Name = g.Name.Name
	}
	if g.Topic != nil {
		group.Topic = g.Topic.Topic
	}
	if err := p.repo.UpsertGroup(ctx, group); err != nil {
		return err
	}
	if group.Name != "" {
		return p.repo.UpsertChat(ctx, database.Chat{
			JID:  group.JID,
			Kind: "group",
			Name: group.Name,
		})
	}
	return nil
}

// persistHistory ingests one HistorySync batch. Conversation/message inserts
// are idempotent (message PK = MessageID), so replaying a batch is safe.
func (p *Persister) persistHistory(ctx context.Context, h *events.HistorySync) error {
	if h == nil || h.Data == nil {
		return nil
	}
	data := h.Data

	for _, pn := range data.GetPushnames() {
		if pn.GetID() == "" {
			continue
		}
		if err := p.repo.UpsertContact(ctx, database.Contact{
			JID:      pn.GetID(),
			PushName: pn.GetPushname(),
		}); err != nil {
			return err
		}
	}
	for _, ic := range data.GetInlineContacts() {
		jid := ic.GetPnJID()
		if jid == "" {
			jid = ic.GetLidJID()
		}
		if jid == "" {
			continue
		}
		if err := p.repo.UpsertContact(ctx, database.Contact{
			JID:       jid,
			FirstName: ic.GetFirstName(),
			FullName:  ic.GetFullName(),
		}); err != nil {
			return err
		}
	}

	// Each conversation is applied in one transaction to amortize the
	// per-statement fsync cost while keeping the inserts idempotent (replaying
	// a batch remains safe). Prioritizing or parallelizing history sync
	// relative to live events, in a separate lane, is deferred to the work
	// before F4.
	for _, conv := range data.GetConversations() {
		if err := p.repo.WithTx(ctx, func(tx *database.Repo) error {
			return p.persistConversation(ctx, tx, conv.GetID(), conv.GetDisplayName(), conv.GetName(),
				conv.GetLastMsgTimestamp(), int(conv.GetUnreadCount()), conv.GetMessages(), h)
		}); err != nil {
			return err
		}
	}

	// Bookkeeping: mark the sync as complete once the server reports 100%.
	if data.GetProgress() >= 100 {
		if err := p.repo.SetSyncState(ctx, "history_done", "1"); err != nil {
			return err
		}
	} else {
		if err := p.repo.SetSyncState(ctx, "history_progress",
			strconv.FormatUint(uint64(data.GetProgress()), 10)); err != nil {
			return err
		}
	}
	if err := p.repo.SetSyncState(ctx, "history_last_sync",
		strconv.FormatInt(time.Now().UnixMilli(), 10)); err != nil {
		return err
	}
	return nil
}

// persistConversation handles a single history conversation. repo is the
// transaction-bound repository supplied by persistHistory.
func (p *Persister) persistConversation(
	ctx context.Context,
	repo *database.Repo,
	chatJID, displayName, name string,
	lastTS uint64,
	unread int,
	messages []*waHistorySync.HistorySyncMsg,
	h *events.HistorySync,
) error {
	if chatJID == "" {
		return nil
	}
	parsed, err := types.ParseJID(chatJID)
	if err != nil {
		return nil
	}
	kind := "dm"
	if parsed.Server == types.GroupServer {
		kind = "group"
	}
	chatName := displayName
	if chatName == "" {
		chatName = name
	}
	if chatName == "" {
		chatName = p.resolveName(ctx, repo, chatJID, "")
	}
	if err := repo.UpsertChat(ctx, database.Chat{JID: chatJID, Kind: kind, Name: chatName}); err != nil {
		return err
	}

	// Messages first: UpdateChatLastMessage inside persistMessage keeps the
	// newest timestamp, and the conversation values below are authoritative.
	for _, hm := range messages {
		if hm == nil || hm.GetMessage() == nil {
			continue
		}
		ev, perr := p.parseWebMessage(parsed, hm.GetMessage())
		if perr != nil {
			p.logger.Debug("whatsapp: history message skipped",
				slog.String("error", perr.Error()))
			continue
		}
		if err := p.persistMessageWithRepo(ctx, repo, ev); err != nil {
			return err
		}
	}
	if lastTS > 0 {
		if err := repo.SetChatLastTimestamp(ctx, chatJID, int64(lastTS)*1000); err != nil {
			return err
		}
	}
	// History sync is authoritative about the unread count.
	return repo.SetUnread(ctx, chatJID, unread)
}

// resolveName returns the best display name for jid: contact (full then first)
// > push > "" (caller falls back to the JID). repo is passed explicitly so the
// lookup can run inside the caller's transaction.
func (p *Persister) resolveName(ctx context.Context, repo *database.Repo, jid, push string) string {
	if c, err := repo.GetContact(ctx, jid); err == nil {
		if c.FullName != "" {
			return c.FullName
		}
		if c.FirstName != "" {
			return c.FirstName
		}
	}
	if push != "" {
		return push
	}
	return ""
}

// extractText returns the human-readable text and a coarse type for a message.
func extractText(m *waE2E.Message) (string, string) {
	if m == nil {
		return "", "unknown"
	}
	switch {
	case m.GetConversation() != "":
		return m.GetConversation(), "text"
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetText(), "text"
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetCaption(), "image"
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetCaption(), "video"
	case m.GetAudioMessage() != nil:
		return "", "audio"
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetCaption(), "document"
	case m.GetStickerMessage() != nil:
		return "", "sticker"
	case m.GetLocationMessage() != nil:
		return "", "location"
	case m.GetContactMessage() != nil:
		return "", "contact"
	case m.GetReactionMessage() != nil:
		return m.GetReactionMessage().GetText(), "reaction"
	case m.GetProtocolMessage() != nil:
		return "", "protocol"
	default:
		return "", "unknown"
	}
}

// extractQuotedID returns the stanza id of the quoted message, when present.
func extractQuotedID(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	if ci := m.GetExtendedTextMessage().GetContextInfo(); ci != nil {
		return ci.GetStanzaID()
	}
	if ci := m.GetImageMessage().GetContextInfo(); ci != nil {
		return ci.GetStanzaID()
	}
	if ci := m.GetVideoMessage().GetContextInfo(); ci != nil {
		return ci.GetStanzaID()
	}
	if ci := m.GetDocumentMessage().GetContextInfo(); ci != nil {
		return ci.GetStanzaID()
	}
	return ""
}

// preview builds the chat list preview for a message.
func preview(text, mtype string) string {
	if text != "" {
		return text
	}
	return "[" + mtype + "]"
}

// initialStatus is the status stored for a freshly persisted message.
func initialStatus(fromMe bool) string {
	if fromMe {
		return "sent"
	}
	return ""
}
