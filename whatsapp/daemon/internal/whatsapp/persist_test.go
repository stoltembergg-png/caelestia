package whatsapp

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// newTestPersister builds a Persister over a temporary database without a live
// client, plus the repository for assertions. The inbox/done channels are
// initialized so tests can exercise the worker loop.
func newTestPersister(t *testing.T) (*Persister, *database.Repo, context.Context) {
	t.Helper()

	db, err := database.Open(filepath.Join(t.TempDir(), "whatsapp.db"))
	if err != nil {
		t.Fatalf("database.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	repo := database.NewRepo(db)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	svc := &Service{logger: logger, ctx: ctx, cancel: cancel}
	p := &Persister{
		svc:      svc,
		repo:     repo,
		logger:   logger,
		thumbDir: t.TempDir(),
		inbox:    make(chan any, eventBufferSize*4),
		done:     make(chan struct{}),
	}
	return p, repo, ctx
}

func testMessage(id, chatJID, senderJID string, fromMe bool, ts int64, text string) *events.Message {
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:     mustJID(chatJID),
				Sender:   mustJID(senderJID),
				IsFromMe: fromMe,
			},
			ID:        id,
			Timestamp: time.UnixMilli(ts),
		},
		Message: &waE2E.Message{Conversation: proto.String(text)},
	}
}

func mustJID(s string) types.JID {
	jid, err := types.ParseJID(s)
	if err != nil {
		panic(err)
	}
	return jid
}

func TestPersistMessageStoresChatContactAndUnread(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	// A pre-existing contact with a full name must win over the push name.
	if err := repo.UpsertContact(ctx, database.Contact{JID: "alice@s.whatsapp.net", FullName: "Alice"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}

	msg := testMessage("m1", "alice@s.whatsapp.net", "alice@s.whatsapp.net", false, 1000, "hi there")
	msg.Info.PushName = "alice push"
	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	chat, err := repo.GetChat(ctx, "alice@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Alice" {
		t.Fatalf("chat name = %q, want Alice (contact wins)", chat.Name)
	}
	if chat.UnreadCount != 1 {
		t.Fatalf("unread = %d, want 1", chat.UnreadCount)
	}
	if chat.LastMessageID != "m1" || chat.LastMessageTS != 1000 || chat.LastPreview != "hi there" {
		t.Fatalf("last = %q/%d/%q, want m1/1000/hi there", chat.LastMessageID, chat.LastMessageTS, chat.LastPreview)
	}

	msgs, err := repo.ListMessages(ctx, "alice@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 1 || msgs[0].Text != "hi there" {
		t.Fatalf("messages = %+v, want one with text", msgs)
	}
}

func TestPersistMessageIsIdempotent(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	msg := testMessage("m1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 1000, "yo")

	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage (duplicate): %v", err)
	}

	msgs, err := repo.ListMessages(ctx, "bob@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("messages = %d, want 1", len(msgs))
	}
	chat, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.UnreadCount != 1 {
		t.Fatalf("unread = %d, want 1 (no double count)", chat.UnreadCount)
	}
}

func TestPersistFromMeDoesNotIncrementUnread(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	if err := p.persistMessage(ctx, testMessage("m1", "bob@s.whatsapp.net", "me@s.whatsapp.net", true, 1000, "sent")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	chat, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.UnreadCount != 0 {
		t.Fatalf("unread = %d, want 0 for an outgoing message", chat.UnreadCount)
	}
}

func TestPersistGroupMessageUsesSenderAsContact(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	if err := repo.UpsertGroup(ctx, database.Group{JID: "g@g.us", Name: "Group A"}); err != nil {
		t.Fatalf("UpsertGroup: %v", err)
	}
	msg := testMessage("m1", "g@g.us", "carol@s.whatsapp.net", false, 1000, "hello group")
	msg.Info.IsGroup = true
	msg.Info.PushName = "Carol"
	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	chat, err := repo.GetChat(ctx, "g@g.us")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Kind != "group" || chat.Name != "Group A" {
		t.Fatalf("chat = %+v, want group/Group A", chat)
	}
	if _, err := repo.GetContact(ctx, "carol@s.whatsapp.net"); err != nil {
		t.Fatalf("GetContact(carol): %v", err)
	}
}

func TestPersistProtocolRevokeAndEdit(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	if err := p.persistMessage(ctx, testMessage("m1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 1000, "original")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	revoke := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			ID:            "m1",
			Timestamp:     time.UnixMilli(2000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
			Key:  &waCommon.MessageKey{ID: proto.String("m1"), RemoteJID: proto.String("bob@s.whatsapp.net")},
		}},
	}
	if err := p.persistMessage(ctx, revoke); err != nil {
		t.Fatalf("persistMessage(revoke): %v", err)
	}
	m, err := repo.GetMessage(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if !m.Deleted {
		t.Fatalf("message not marked deleted: %+v", m)
	}

	// Re-store an editable message and apply an edit.
	if err := p.persistMessage(ctx, testMessage("m2", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 3000, "before")); err != nil {
		t.Fatalf("persistMessage(m2): %v", err)
	}
	edit := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			ID:            "m2",
			Timestamp:     time.UnixMilli(4000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type:          waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(),
			Key:           &waCommon.MessageKey{ID: proto.String("m2")},
			EditedMessage: &waE2E.Message{Conversation: proto.String("after")},
		}},
	}
	if err := p.persistMessage(ctx, edit); err != nil {
		t.Fatalf("persistMessage(edit): %v", err)
	}
	m, err = repo.GetMessage(ctx, "m2")
	if err != nil {
		t.Fatalf("GetMessage(m2): %v", err)
	}
	if !m.Edited || m.Text != "after" {
		t.Fatalf("message = %+v, want edited text after", m)
	}
}

func TestPersistReceiptUpdatesStatusAndUnread(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	// An outgoing message we sent.
	if err := p.persistMessage(ctx, testMessage("out1", "bob@s.whatsapp.net", "me@s.whatsapp.net", true, 1000, "sent")); err != nil {
		t.Fatalf("persistMessage(out): %v", err)
	}
	delivered := &events.Receipt{
		MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
		MessageIDs:    []types.MessageID{"out1"},
		Timestamp:     time.UnixMilli(2000),
		Type:          types.ReceiptTypeDelivered,
	}
	if err := p.persistReceipt(ctx, delivered); err != nil {
		t.Fatalf("persistReceipt(delivered): %v", err)
	}
	m, err := repo.GetMessage(ctx, "out1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if m.Status != "delivered" {
		t.Fatalf("status = %q, want delivered", m.Status)
	}

	// One incoming message, then a read receipt from our own device clears it.
	if err := p.persistMessage(ctx, testMessage("in1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 3000, "reply")); err != nil {
		t.Fatalf("persistMessage(in): %v", err)
	}
	readSelf := &events.Receipt{
		MessageSource: types.MessageSource{
			Chat:     mustJID("bob@s.whatsapp.net"),
			Sender:   mustJID("me@s.whatsapp.net"),
			IsFromMe: true,
		},
		MessageIDs: []types.MessageID{"in1"},
		Timestamp:  time.UnixMilli(4000),
		Type:       types.ReceiptTypeReadSelf,
	}
	if err := p.persistReceipt(ctx, readSelf); err != nil {
		t.Fatalf("persistReceipt(readSelf): %v", err)
	}
	chat, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.UnreadCount != 0 {
		t.Fatalf("unread = %d, want 0 after our read", chat.UnreadCount)
	}
}

func historyWebMessage(id, remoteJID string, fromMe bool, ts uint64) *waWeb.WebMessageInfo {
	return &waWeb.WebMessageInfo{
		Key: &waCommon.MessageKey{
			ID:        proto.String(id),
			RemoteJID: proto.String(remoteJID),
			FromMe:    proto.Bool(fromMe),
		},
		MessageTimestamp: proto.Uint64(ts),
		Message:          &waE2E.Message{Conversation: proto.String("history " + id)},
	}
}

func TestPersistHistorySync(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	// Stub the whatsmeow parser; the real one needs a live session.
	p.parseWebMessage = func(chatJID types.JID, wm *waWeb.WebMessageInfo) (*events.Message, error) {
		return &events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{
					Chat:     chatJID,
					Sender:   chatJID,
					IsFromMe: wm.GetKey().GetFromMe(),
				},
				ID:        wm.GetKey().GetID(),
				Timestamp: time.Unix(int64(wm.GetMessageTimestamp()), 0),
			},
			Message: wm.GetMessage(),
		}, nil
	}

	data := &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_FULL.Enum(),
		Progress: proto.Uint32(100),
		Pushnames: []*waHistorySync.Pushname{
			{ID: proto.String("bob@s.whatsapp.net"), Pushname: proto.String("Bobby")},
		},
		Conversations: []*waHistorySync.Conversation{{
			ID:               proto.String("bob@s.whatsapp.net"),
			DisplayName:      proto.String("Bob"),
			LastMsgTimestamp: proto.Uint64(2000),
			UnreadCount:      proto.Uint32(2),
			Messages: []*waHistorySync.HistorySyncMsg{
				{Message: historyWebMessage("h1", "bob@s.whatsapp.net", false, 1000)},
				{Message: historyWebMessage("h2", "bob@s.whatsapp.net", true, 2000)},
			},
		}},
	}

	if err := p.persistHistory(ctx, &events.HistorySync{Data: data}); err != nil {
		t.Fatalf("persistHistory: %v", err)
	}

	msgs, err := repo.ListMessages(ctx, "bob@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("history messages = %d, want 2", len(msgs))
	}
	chat, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Bob" {
		t.Fatalf("chat name = %q, want Bob", chat.Name)
	}
	if chat.UnreadCount != 2 {
		t.Fatalf("unread = %d, want 2 (history is authoritative)", chat.UnreadCount)
	}
	if v, err := repo.GetSyncState(ctx, "history_done"); err != nil || v != "1" {
		t.Fatalf("history_done = %q, %v; want 1", v, err)
	}

	// Replaying the same batch must not duplicate or double count.
	if err := p.persistHistory(ctx, &events.HistorySync{Data: data}); err != nil {
		t.Fatalf("persistHistory (replay): %v", err)
	}
	msgs, err = repo.ListMessages(ctx, "bob@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages (replay): %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("messages after replay = %d, want 2", len(msgs))
	}
}

func TestPersistContactAndGroup(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	if err := p.persistContact(ctx, &events.Contact{
		JID: mustJID("dave@s.whatsapp.net"),
		Action: &waSyncAction.ContactAction{
			FullName:  proto.String("Dave"),
			FirstName: proto.String("D"),
		},
	}); err != nil {
		t.Fatalf("persistContact: %v", err)
	}
	if c, err := repo.GetContact(ctx, "dave@s.whatsapp.net"); err != nil || c.FullName != "Dave" {
		t.Fatalf("contact = %+v, %v; want full name Dave", c, err)
	}

	if err := p.persistGroup(ctx, &events.GroupInfo{
		JID:  mustJID("g@g.us"),
		Name: &types.GroupName{Name: "The Group"},
	}); err != nil {
		t.Fatalf("persistGroup: %v", err)
	}
	if g, err := repo.GetGroup(ctx, "g@g.us"); err != nil || g.Name != "The Group" {
		t.Fatalf("group = %+v, %v; want name The Group", g, err)
	}
}

// reactionMessage builds a ReactionMessage event targeting targetID.
func reactionMessage(id, chatJID, senderJID, targetID, emoji string, ts int64) *events.Message {
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:   mustJID(chatJID),
				Sender: mustJID(senderJID),
			},
			ID:        id,
			Timestamp: time.UnixMilli(ts),
		},
		Message: &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{
			Key:  &waCommon.MessageKey{ID: proto.String(targetID)},
			Text: proto.String(emoji),
		}},
	}
}

func TestPersistReactionDoesNotTouchUnreadOrLastMessage(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	// Seed a real message so the chat has last_message/preview/unread state.
	if err := p.persistMessage(ctx, testMessage("m1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 1000, "hello")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	before, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if before.UnreadCount != 1 || before.LastMessageID != "m1" {
		t.Fatalf("seed chat = %+v, want unread 1 and last m1", before)
	}

	if err := p.persistMessage(ctx, reactionMessage("react1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", "m1", "👍", 2000)); err != nil {
		t.Fatalf("persistMessage(reaction): %v", err)
	}

	after, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if after.UnreadCount != before.UnreadCount {
		t.Fatalf("unread changed by reaction: %d -> %d", before.UnreadCount, after.UnreadCount)
	}
	if after.LastMessageID != before.LastMessageID || after.LastMessageTS != before.LastMessageTS || after.LastPreview != before.LastPreview {
		t.Fatalf("last message changed by reaction: %+v -> %+v", before, after)
	}

	// A reaction must not create a message row.
	msgs, err := repo.ListMessages(ctx, "bob@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 1 || msgs[0].ID != "m1" {
		t.Fatalf("messages = %+v, want only m1", msgs)
	}

	// It is stored as metadata keyed by (message, sender).
	rs, err := repo.ListReactions(ctx, "m1")
	if err != nil {
		t.Fatalf("ListReactions: %v", err)
	}
	if len(rs) != 1 || rs[0].Emoji != "👍" || rs[0].SenderJID != "bob@s.whatsapp.net" {
		t.Fatalf("reactions = %+v, want 👍 from bob", rs)
	}

	// An empty reaction text removes it.
	if err := p.persistMessage(ctx, reactionMessage("react2", "bob@s.whatsapp.net", "bob@s.whatsapp.net", "m1", "", 3000)); err != nil {
		t.Fatalf("persistMessage(reaction removal): %v", err)
	}
	rs, err = repo.ListReactions(ctx, "m1")
	if err != nil {
		t.Fatalf("ListReactions: %v", err)
	}
	if len(rs) != 0 {
		t.Fatalf("reactions after removal = %+v, want none", rs)
	}
}

func TestPersistProtocolMessageIgnored(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	protoMsg := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:   mustJID("bob@s.whatsapp.net"),
				Sender: mustJID("bob@s.whatsapp.net"),
			},
			ID:        "proto1",
			Timestamp: time.UnixMilli(1000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_EPHEMERAL_SETTING.Enum(),
		}},
	}
	if err := p.persistMessage(ctx, protoMsg); err != nil {
		t.Fatalf("persistMessage(protocol): %v", err)
	}

	// No row at all: neither a message nor even a chat.
	if _, err := repo.GetChat(ctx, "bob@s.whatsapp.net"); !errors.Is(err, database.ErrNotFound) {
		t.Fatalf("GetChat = %v, want ErrNotFound (protocol must not create a chat)", err)
	}
	msgs, err := repo.ListMessages(ctx, "bob@s.whatsapp.net", 10, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 0 {
		t.Fatalf("messages = %+v, want none for a protocol event", msgs)
	}
}

func TestPersistFromMeDoesNotOverwriteContact(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	if err := repo.UpsertContact(ctx, database.Contact{JID: "bob@s.whatsapp.net", FullName: "Bob"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}

	out := testMessage("m1", "bob@s.whatsapp.net", "me@s.whatsapp.net", true, 1000, "sent")
	out.Info.PushName = "My Own Name"
	if err := p.persistMessage(ctx, out); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	c, err := repo.GetContact(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetContact: %v", err)
	}
	if c.FullName != "Bob" {
		t.Fatalf("full name = %q, want Bob", c.FullName)
	}
	if c.PushName == "My Own Name" {
		t.Fatalf("outgoing message wrote our own push name onto the peer: %+v", c)
	}
	if _, err := repo.GetContact(ctx, "me@s.whatsapp.net"); !errors.Is(err, database.ErrNotFound) {
		t.Fatalf("GetContact(me) = %v, want ErrNotFound", err)
	}
}

func TestDrainProcessesBufferedEvents(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	const n = 5
	for i := 0; i < n; i++ {
		p.inbox <- testMessage(fmt.Sprintf("d%d", i), "drain@s.whatsapp.net", "drain@s.whatsapp.net", false, int64(1000+i), "x")
	}
	p.drain()

	msgs, err := repo.ListMessages(ctx, "drain@s.whatsapp.net", 100, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != n {
		t.Fatalf("drained %d messages, want %d", len(msgs), n)
	}
}

func TestPersisterCloseDrainsInbox(t *testing.T) {
	p, repo, ctx := newTestPersister(t)

	// Fill the inbox before the worker starts, then shut down: Close must
	// process everything that was already accepted instead of dropping it.
	const n = 30
	for i := 0; i < n; i++ {
		p.inbox <- testMessage(fmt.Sprintf("close-%02d", i), "close@s.whatsapp.net", "close@s.whatsapp.net", false, int64(1000+i), "x")
	}

	p.wg.Add(1)
	go p.run()
	p.Close()

	msgs, err := repo.ListMessages(ctx, "close@s.whatsapp.net", 100, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != n {
		t.Fatalf("after Close: %d messages, want %d (events were dropped)", len(msgs), n)
	}
}

// domainEvent is one captured OnDomainEvent callback.
type domainEvent struct {
	name string
	data map[string]any
}

// eventRecorder is a thread-safe OnDomainEvent sink for assertions.
type eventRecorder struct {
	mu     sync.Mutex
	events []domainEvent
}

func (r *eventRecorder) hook(name string, data any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	m, _ := data.(map[string]any)
	r.events = append(r.events, domainEvent{name: name, data: m})
}

func (r *eventRecorder) list() []domainEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]domainEvent(nil), r.events...)
}

func (r *eventRecorder) reset() {
	r.mu.Lock()
	r.events = nil
	r.mu.Unlock()
}

func eventByName(events []domainEvent, name string) []domainEvent {
	var out []domainEvent
	for _, e := range events {
		if e.name == name {
			out = append(out, e)
		}
	}
	return out
}

func TestPersisterEmitsMessageReceivedAndChatUpdated(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	rec := &eventRecorder{}

	// The hook must run only after the message is committed: assert the row is
	// already readable from the database while handling message.received.
	persistedAtEmit := false
	p.OnDomainEvent(func(name string, data any) {
		if name == EventMessageReceived {
			if _, err := repo.GetMessage(ctx, "m1"); err == nil {
				persistedAtEmit = true
			}
		}
		rec.hook(name, data)
	})

	msg := testMessage("m1", "alice@s.whatsapp.net", "alice@s.whatsapp.net", false, 1730000000000, "hi there")
	msg.Info.PushName = "Alice"
	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	if !persistedAtEmit {
		t.Fatal("message.received was emitted before the message was persisted")
	}

	events := rec.list()
	if len(events) != 2 {
		t.Fatalf("events = %+v, want message.received then chat.updated", events)
	}

	got := events[0]
	if got.name != EventMessageReceived {
		t.Fatalf("first event = %q, want %q", got.name, EventMessageReceived)
	}
	want := map[string]any{
		"chat":      "alice@s.whatsapp.net",
		"sender":    "alice@s.whatsapp.net",
		"id":        "m1",
		"text":      "hi there",
		"timestamp": "1730000000000",
		"from_me":   false,
		"type":      "text",
	}
	for k, v := range want {
		if got.data[k] != v {
			t.Errorf("message.received[%q] = %v (%T), want %v (%T)", k, got.data[k], got.data[k], v, v)
		}
	}

	cu := events[1]
	if cu.name != EventChatUpdated {
		t.Fatalf("second event = %q, want %q", cu.name, EventChatUpdated)
	}
	wantCU := map[string]any{
		"jid":          "alice@s.whatsapp.net",
		"name":         "Alice",
		"unread":       1,
		"last_message": "hi there",
		"last_ts":      "1730000000000",
	}
	for k, v := range wantCU {
		if cu.data[k] != v {
			t.Errorf("chat.updated[%q] = %v, want %v", k, cu.data[k], v)
		}
	}

	// A duplicate insert is a no-op: it must not re-emit anything.
	rec.reset()
	if err := p.persistMessage(ctx, msg); err != nil {
		t.Fatalf("persistMessage (duplicate): %v", err)
	}
	if evs := rec.list(); len(evs) != 0 {
		t.Fatalf("duplicate message emitted events: %+v", evs)
	}
}

func TestPersisterEmitsOwnEchoAsMessageReceived(t *testing.T) {
	p, _, ctx := newTestPersister(t)
	rec := &eventRecorder{}
	p.OnDomainEvent(rec.hook)

	if err := p.persistMessage(ctx, testMessage("me1", "bob@s.whatsapp.net", "me@s.whatsapp.net", true, 1000, "sent")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	rx := eventByName(rec.list(), EventMessageReceived)
	if len(rx) != 1 {
		t.Fatalf("message.received count = %d, want 1 (own echo)", len(rx))
	}
	if rx[0].data["from_me"] != true {
		t.Fatalf("from_me = %v, want true", rx[0].data["from_me"])
	}
	if rx[0].data["sender"] != "me@s.whatsapp.net" {
		t.Fatalf("sender = %v, want me@s.whatsapp.net", rx[0].data["sender"])
	}
	if rx[0].data["text"] != "sent" {
		t.Fatalf("text = %v, want sent", rx[0].data["text"])
	}
}

func TestPersisterEmitsReceiptUpdated(t *testing.T) {
	t.Run("delivered keeps unread and emits only receipt.updated", func(t *testing.T) {
		p, _, ctx := newTestPersister(t)
		rec := &eventRecorder{}
		p.OnDomainEvent(rec.hook)

		if err := p.persistMessage(ctx, testMessage("out1", "bob@s.whatsapp.net", "me@s.whatsapp.net", true, 1000, "sent")); err != nil {
			t.Fatalf("persistMessage: %v", err)
		}
		rec.reset()

		if err := p.persistReceipt(ctx, &events.Receipt{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			MessageIDs:    []types.MessageID{"out1"},
			Timestamp:     time.UnixMilli(2000),
			Type:          types.ReceiptTypeDelivered,
		}); err != nil {
			t.Fatalf("persistReceipt: %v", err)
		}

		events := rec.list()
		if len(events) != 1 || events[0].name != EventReceiptUpdated {
			t.Fatalf("events = %+v, want a single receipt.updated", events)
		}
		if events[0].data["chat"] != "bob@s.whatsapp.net" || events[0].data["status"] != "delivered" {
			t.Fatalf("receipt.updated = %+v", events[0].data)
		}
		ids, ok := events[0].data["ids"].([]string)
		if !ok || len(ids) != 1 || ids[0] != "out1" {
			t.Fatalf("receipt.updated ids = %#v, want [out1]", events[0].data["ids"])
		}
	})

	t.Run("read clears unread and emits chat.updated", func(t *testing.T) {
		p, _, ctx := newTestPersister(t)
		rec := &eventRecorder{}
		p.OnDomainEvent(rec.hook)

		if err := p.persistMessage(ctx, testMessage("in1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 3000, "reply")); err != nil {
			t.Fatalf("persistMessage: %v", err)
		}
		rec.reset()

		if err := p.persistReceipt(ctx, &events.Receipt{
			MessageSource: types.MessageSource{
				Chat:     mustJID("bob@s.whatsapp.net"),
				Sender:   mustJID("me@s.whatsapp.net"),
				IsFromMe: true,
			},
			MessageIDs: []types.MessageID{"in1"},
			Timestamp:  time.UnixMilli(4000),
			Type:       types.ReceiptTypeReadSelf,
		}); err != nil {
			t.Fatalf("persistReceipt: %v", err)
		}

		events := rec.list()
		if len(events) != 2 {
			t.Fatalf("events = %+v, want receipt.updated then chat.updated", events)
		}
		if events[0].name != EventReceiptUpdated || events[0].data["status"] != "read" {
			t.Fatalf("first event = %+v, want receipt.updated/read", events[0])
		}
		if events[1].name != EventChatUpdated {
			t.Fatalf("second event = %+v, want chat.updated", events[1])
		}
		if events[1].data["unread"] != 0 {
			t.Fatalf("chat.updated unread = %v, want 0", events[1].data["unread"])
		}
	})
}

func TestPersisterEmitsMessageUpdatedForEditAndRevoke(t *testing.T) {
	p, _, ctx := newTestPersister(t)
	rec := &eventRecorder{}
	p.OnDomainEvent(rec.hook)

	// Seed two messages so the protocol mutations have a target.
	for _, id := range []string{"m1", "m2"} {
		if err := p.persistMessage(ctx, testMessage(id, "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 1000, "original "+id)); err != nil {
			t.Fatalf("persistMessage(%s): %v", id, err)
		}
	}
	rec.reset()

	revoke := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			ID:            "m1",
			Timestamp:     time.UnixMilli(2000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
			Key:  &waCommon.MessageKey{ID: proto.String("m1")},
		}},
	}
	if err := p.persistMessage(ctx, revoke); err != nil {
		t.Fatalf("persistMessage(revoke): %v", err)
	}
	evs := rec.list()
	if len(evs) != 1 || evs[0].name != EventMessageUpdated {
		t.Fatalf("revoke events = %+v, want one message.updated", evs)
	}
	if evs[0].data["id"] != "m1" || evs[0].data["chat"] != "bob@s.whatsapp.net" || evs[0].data["deleted"] != true {
		t.Fatalf("revoke payload = %+v", evs[0].data)
	}
	if _, has := evs[0].data["edited"]; has {
		t.Fatalf("revoke payload must not carry edited: %+v", evs[0].data)
	}
	rec.reset()

	edit := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			ID:            "m2",
			Timestamp:     time.UnixMilli(4000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type:          waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(),
			Key:           &waCommon.MessageKey{ID: proto.String("m2")},
			EditedMessage: &waE2E.Message{Conversation: proto.String("after")},
		}},
	}
	if err := p.persistMessage(ctx, edit); err != nil {
		t.Fatalf("persistMessage(edit): %v", err)
	}
	evs = rec.list()
	if len(evs) != 1 || evs[0].name != EventMessageUpdated {
		t.Fatalf("edit events = %+v, want one message.updated", evs)
	}
	if evs[0].data["id"] != "m2" || evs[0].data["edited"] != true {
		t.Fatalf("edit payload = %+v", evs[0].data)
	}
	if _, has := evs[0].data["deleted"]; has {
		t.Fatalf("edit payload must not carry deleted: %+v", evs[0].data)
	}
}

func TestPersisterEmitsNothingForIgnoredEvents(t *testing.T) {
	p, _, ctx := newTestPersister(t)
	rec := &eventRecorder{}
	p.OnDomainEvent(rec.hook)

	// Seed a message the reaction targets, then clear the seed events.
	if err := p.persistMessage(ctx, testMessage("m1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", false, 1000, "hello")); err != nil {
		t.Fatalf("persistMessage(seed): %v", err)
	}
	rec.reset()

	if err := p.persistMessage(ctx, reactionMessage("react1", "bob@s.whatsapp.net", "bob@s.whatsapp.net", "m1", "👍", 2000)); err != nil {
		t.Fatalf("persistMessage(reaction): %v", err)
	}
	// A protocol message that is neither REVOKE nor MESSAGE_EDIT.
	ignored := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: mustJID("bob@s.whatsapp.net"), Sender: mustJID("bob@s.whatsapp.net")},
			ID:            "proto1",
			Timestamp:     time.UnixMilli(3000),
		},
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Type: waE2E.ProtocolMessage_EPHEMERAL_SETTING.Enum(),
		}},
	}
	if err := p.persistMessage(ctx, ignored); err != nil {
		t.Fatalf("persistMessage(protocol): %v", err)
	}

	if evs := rec.list(); len(evs) != 0 {
		t.Fatalf("ignored events emitted domain events: %+v", evs)
	}
}

func TestPersisterHistoryDoesNotEmitDomainEvents(t *testing.T) {
	p, _, ctx := newTestPersister(t)
	p.parseWebMessage = func(chatJID types.JID, wm *waWeb.WebMessageInfo) (*events.Message, error) {
		return &events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{
					Chat:     chatJID,
					Sender:   chatJID,
					IsFromMe: wm.GetKey().GetFromMe(),
				},
				ID:        wm.GetKey().GetID(),
				Timestamp: time.Unix(int64(wm.GetMessageTimestamp()), 0),
			},
			Message: wm.GetMessage(),
		}, nil
	}
	rec := &eventRecorder{}
	p.OnDomainEvent(rec.hook)

	data := &waHistorySync.HistorySync{
		Progress: proto.Uint32(100),
		Conversations: []*waHistorySync.Conversation{{
			ID: proto.String("bob@s.whatsapp.net"),
			Messages: []*waHistorySync.HistorySyncMsg{
				{Message: historyWebMessage("h1", "bob@s.whatsapp.net", false, 1000)},
			},
		}},
	}
	if err := p.persistHistory(ctx, &events.HistorySync{Data: data}); err != nil {
		t.Fatalf("persistHistory: %v", err)
	}
	if evs := rec.list(); len(evs) != 0 {
		t.Fatalf("history sync emitted domain events: %+v", evs)
	}
}
