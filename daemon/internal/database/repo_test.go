package database

import (
	"context"
	"errors"
	"testing"
)

func newTestRepo(t *testing.T) (*Repo, context.Context) {
	t.Helper()
	db, _ := openTestDB(t)
	return NewRepo(db), context.Background()
}

// mustChat inserts a chat used as a foreign-key parent.
func mustChat(t *testing.T, r *Repo, ctx context.Context, jid string) {
	t.Helper()
	if err := r.UpsertChat(ctx, Chat{JID: jid, Kind: "dm", Name: "name-" + jid}); err != nil {
		t.Fatalf("UpsertChat(%q): %v", jid, err)
	}
}

func mustMessage(t *testing.T, r *Repo, ctx context.Context, m Message) bool {
	t.Helper()
	inserted, err := r.InsertMessage(ctx, m)
	if err != nil {
		t.Fatalf("InsertMessage(%q): %v", m.ID, err)
	}
	return inserted
}

func TestInsertMessageIsIdempotent(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")

	m := Message{
		ID:        "MSG1",
		ChatJID:   "chat@s.whatsapp.net",
		SenderJID: "chat@s.whatsapp.net",
		Timestamp: 1000,
		Type:      "text",
		Text:      "hello",
	}
	if !mustMessage(t, r, ctx, m) {
		t.Fatal("first insert reported not inserted")
	}
	if mustMessage(t, r, ctx, m) {
		t.Fatal("second insert of the same id reported inserted, want no-op")
	}

	msgs, err := r.ListMessages(ctx, "chat@s.whatsapp.net", 0, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("message count = %d, want 1", len(msgs))
	}
}

func TestListChatsOrderingAndPagination(t *testing.T) {
	r, ctx := newTestRepo(t)

	// Insert chats out of order with explicit timestamps.
	for i, ts := range []int64{300, 100, 200} {
		jid := []string{"chat-c", "chat-a", "chat-b"}[i]
		if err := r.UpsertChat(ctx, Chat{JID: jid}); err != nil {
			t.Fatalf("UpsertChat: %v", err)
		}
		if err := r.UpdateChatLastMessage(ctx, jid, "m", ts, "p"); err != nil {
			t.Fatalf("UpdateChatLastMessage: %v", err)
		}
	}
	// A chat without any message sorts last.
	if err := r.UpsertChat(ctx, Chat{JID: "chat-none"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}

	all, err := r.ListChats(ctx, 10)
	if err != nil {
		t.Fatalf("ListChats: %v", err)
	}
	want := []string{"chat-c", "chat-b", "chat-a", "chat-none"}
	if len(all) != len(want) {
		t.Fatalf("chat count = %d, want %d", len(all), len(want))
	}
	for i := range want {
		if all[i].JID != want[i] {
			t.Fatalf("chat[%d] = %q, want %q", i, all[i].JID, want[i])
		}
	}

	page, err := r.ListChats(ctx, 2)
	if err != nil {
		t.Fatalf("ListChats(limit=2): %v", err)
	}
	if len(page) != 2 || page[0].JID != "chat-c" || page[1].JID != "chat-b" {
		t.Fatalf("page = %+v, want chat-c, chat-b", page)
	}
}

func TestUpdateChatLastMessageKeepsNewest(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")

	if err := r.UpdateChatLastMessage(ctx, "chat@s.whatsapp.net", "new", 500, "newer"); err != nil {
		t.Fatalf("update new: %v", err)
	}
	// An older message must not overwrite the stored last message.
	if err := r.UpdateChatLastMessage(ctx, "chat@s.whatsapp.net", "old", 100, "older"); err != nil {
		t.Fatalf("update old: %v", err)
	}

	c, err := r.GetChat(ctx, "chat@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if c.LastMessageID != "new" || c.LastMessageTS != 500 || c.LastPreview != "newer" {
		t.Fatalf("chat last = %q/%d/%q, want new/500/newer", c.LastMessageID, c.LastMessageTS, c.LastPreview)
	}
}

func TestListMessagesOrderAndBefore(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")

	for i, ts := range []int64{100, 200, 300, 400} {
		id := []string{"m1", "m2", "m3", "m4"}[i]
		mustMessage(t, r, ctx, Message{ID: id, ChatJID: "chat@s.whatsapp.net", Timestamp: ts, Type: "text"})
	}

	recent, err := r.ListMessages(ctx, "chat@s.whatsapp.net", 2, 0)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	if len(recent) != 2 || recent[0].ID != "m4" || recent[1].ID != "m3" {
		t.Fatalf("recent = %+v, want m4, m3", recent)
	}

	older, err := r.ListMessages(ctx, "chat@s.whatsapp.net", 10, 300)
	if err != nil {
		t.Fatalf("ListMessages(before): %v", err)
	}
	if len(older) != 2 || older[0].ID != "m2" || older[1].ID != "m1" {
		t.Fatalf("older = %+v, want m2, m1", older)
	}
}

func TestUnreadCountersAndMarkRead(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "a@s.whatsapp.net")
	mustChat(t, r, ctx, "b@s.whatsapp.net")

	if err := r.IncrementUnread(ctx, "a@s.whatsapp.net"); err != nil {
		t.Fatalf("IncrementUnread: %v", err)
	}
	if err := r.IncrementUnread(ctx, "a@s.whatsapp.net"); err != nil {
		t.Fatalf("IncrementUnread: %v", err)
	}
	if err := r.SetUnread(ctx, "b@s.whatsapp.net", 5); err != nil {
		t.Fatalf("SetUnread: %v", err)
	}

	total, err := r.UnreadTotal(ctx)
	if err != nil {
		t.Fatalf("UnreadTotal: %v", err)
	}
	if total != 7 {
		t.Fatalf("unread total = %d, want 7", total)
	}

	if err := r.MarkChatRead(ctx, "a@s.whatsapp.net"); err != nil {
		t.Fatalf("MarkChatRead: %v", err)
	}
	c, err := r.GetChat(ctx, "a@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if c.UnreadCount != 0 {
		t.Fatalf("unread after read = %d, want 0", c.UnreadCount)
	}
}

func TestPendingIncomingMessages(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")

	mustMessage(t, r, ctx, Message{ID: "in1", ChatJID: "chat@s.whatsapp.net", SenderJID: "u@s.whatsapp.net", Timestamp: 1})
	mustMessage(t, r, ctx, Message{ID: "out1", ChatJID: "chat@s.whatsapp.net", FromMe: true, Timestamp: 2})
	mustMessage(t, r, ctx, Message{ID: "in-read", ChatJID: "chat@s.whatsapp.net", SenderJID: "u@s.whatsapp.net", Timestamp: 3, Status: "read"})

	pending, err := r.PendingIncomingMessages(ctx, "chat@s.whatsapp.net")
	if err != nil {
		t.Fatalf("PendingIncomingMessages: %v", err)
	}
	if len(pending) != 1 || pending[0].ID != "in1" {
		t.Fatalf("pending = %+v, want [in1]", pending)
	}
}

func TestSetMessagesStatusNoDowngrade(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")
	mustMessage(t, r, ctx, Message{ID: "m1", ChatJID: "chat@s.whatsapp.net", FromMe: true, Timestamp: 1})

	if err := r.SetMessagesStatus(ctx, []string{"m1"}, "read"); err != nil {
		t.Fatalf("set read: %v", err)
	}
	if err := r.SetMessagesStatus(ctx, []string{"m1"}, "delivered"); err != nil {
		t.Fatalf("set delivered: %v", err)
	}
	m, err := r.GetMessage(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if m.Status != "read" {
		t.Fatalf("status = %q, want read (delivered must not downgrade)", m.Status)
	}
}

func TestSetMessageEditedAndDeleted(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")
	mustMessage(t, r, ctx, Message{ID: "m1", ChatJID: "chat@s.whatsapp.net", Timestamp: 1, Text: "old"})

	if err := r.SetMessageEdited(ctx, "m1", "new"); err != nil {
		t.Fatalf("SetMessageEdited: %v", err)
	}
	m, err := r.GetMessage(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if !m.Edited || m.Text != "new" {
		t.Fatalf("message = %+v, want edited text new", m)
	}

	if err := r.SetMessageDeleted(ctx, "m1"); err != nil {
		t.Fatalf("SetMessageDeleted: %v", err)
	}
	m, err = r.GetMessage(ctx, "m1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if !m.Deleted || m.Text != "" {
		t.Fatalf("message = %+v, want deleted with empty text", m)
	}
}

func TestInsertReceipt(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")
	mustMessage(t, r, ctx, Message{ID: "m1", ChatJID: "chat@s.whatsapp.net", FromMe: true, Timestamp: 1})

	rec := Receipt{MessageID: "m1", UserJID: "u@s.whatsapp.net", Type: "delivered", TS: 10}
	if err := r.InsertReceipt(ctx, rec); err != nil {
		t.Fatalf("InsertReceipt: %v", err)
	}
	// Idempotent, and the timestamp is updated.
	rec.TS = 20
	if err := r.InsertReceipt(ctx, rec); err != nil {
		t.Fatalf("InsertReceipt (second): %v", err)
	}

	var count int
	if err := r.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM cae_receipts WHERE message_id = 'm1'`).Scan(&count); err != nil {
		t.Fatalf("count receipts: %v", err)
	}
	if count != 1 {
		t.Fatalf("receipt rows = %d, want 1", count)
	}

	// A receipt for an unknown message is ignored, not an error (no FK blow-up).
	if err := r.InsertReceipt(ctx, Receipt{MessageID: "ghost", UserJID: "u@x", Type: "read", TS: 1}); err != nil {
		t.Fatalf("InsertReceipt(ghost): %v", err)
	}
}

func TestUpsertContactAndSearch(t *testing.T) {
	r, ctx := newTestRepo(t)

	if err := r.UpsertContact(ctx, Contact{JID: "b@s.whatsapp.net", FullName: "Bob"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}
	// An empty field must not erase the known name.
	if err := r.UpsertContact(ctx, Contact{JID: "b@s.whatsapp.net", PushName: "bobby"}); err != nil {
		t.Fatalf("UpsertContact (refine): %v", err)
	}
	if err := r.UpsertContact(ctx, Contact{JID: "a@s.whatsapp.net", FirstName: "Alice"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}

	c, err := r.GetContact(ctx, "b@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetContact: %v", err)
	}
	if c.FullName != "Bob" || c.PushName != "bobby" {
		t.Fatalf("contact = %+v, want full=Bob push=bobby", c)
	}

	got, err := r.SearchContacts(ctx, "bob", 10)
	if err != nil {
		t.Fatalf("SearchContacts: %v", err)
	}
	if len(got) != 1 || got[0].JID != "b@s.whatsapp.net" {
		t.Fatalf("search bob = %+v, want b", got)
	}

	if _, err := r.GetContact(ctx, "missing@x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetContact(missing) = %v, want ErrNotFound", err)
	}
}

func TestSyncStateRoundTrip(t *testing.T) {
	r, ctx := newTestRepo(t)

	if _, err := r.GetSyncState(ctx, "history_done"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetSyncState(missing) = %v, want ErrNotFound", err)
	}
	if err := r.SetSyncState(ctx, "history_done", "1"); err != nil {
		t.Fatalf("SetSyncState: %v", err)
	}
	if err := r.SetSyncState(ctx, "history_done", "0"); err != nil {
		t.Fatalf("SetSyncState (update): %v", err)
	}
	v, err := r.GetSyncState(ctx, "history_done")
	if err != nil {
		t.Fatalf("GetSyncState: %v", err)
	}
	if v != "0" {
		t.Fatalf("sync state = %q, want 0", v)
	}
}

func TestUpsertGroup(t *testing.T) {
	r, ctx := newTestRepo(t)

	if err := r.UpsertGroup(ctx, Group{JID: "g@g.us", Name: "Group A"}); err != nil {
		t.Fatalf("UpsertGroup: %v", err)
	}
	if err := r.UpsertGroup(ctx, Group{JID: "g@g.us", Topic: "topic"}); err != nil {
		t.Fatalf("UpsertGroup (topic): %v", err)
	}
	g, err := r.GetGroup(ctx, "g@g.us")
	if err != nil {
		t.Fatalf("GetGroup: %v", err)
	}
	if g.Name != "Group A" || g.Topic != "topic" {
		t.Fatalf("group = %+v, want name=Group A topic=topic", g)
	}
}

func TestSearchContactsEscapesWildcards(t *testing.T) {
	r, ctx := newTestRepo(t)

	for _, c := range []Contact{
		{JID: "pct@s.whatsapp.net", FullName: "100% real"},
		{JID: "under@s.whatsapp.net", FullName: "a_b"},
		{JID: "plain@s.whatsapp.net", FullName: "plain"},
	} {
		if err := r.UpsertContact(ctx, c); err != nil {
			t.Fatalf("UpsertContact(%q): %v", c.JID, err)
		}
	}

	// '%' must be literal: it matches only the contact containing a percent
	// sign, not every contact (which a raw LIKE would do).
	got, err := r.SearchContacts(ctx, "%", 10)
	if err != nil {
		t.Fatalf("SearchContacts(%%): %v", err)
	}
	if len(got) != 1 || got[0].JID != "pct@s.whatsapp.net" {
		t.Fatalf("search %% = %+v, want only pct", got)
	}

	// '_' must be literal too: it must not match an arbitrary single char.
	got, err = r.SearchContacts(ctx, "_", 10)
	if err != nil {
		t.Fatalf("SearchContacts(_): %v", err)
	}
	if len(got) != 1 || got[0].JID != "under@s.whatsapp.net" {
		t.Fatalf("search _ = %+v, want only under", got)
	}

	// A normal query still works.
	got, err = r.SearchContacts(ctx, "plai", 10)
	if err != nil {
		t.Fatalf("SearchContacts(plai): %v", err)
	}
	if len(got) != 1 || got[0].JID != "plain@s.whatsapp.net" {
		t.Fatalf("search plai = %+v, want only plain", got)
	}
}

func TestReactionUpsertAndDelete(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")
	mustMessage(t, r, ctx, Message{ID: "m1", ChatJID: "chat@s.whatsapp.net", Timestamp: 1})

	// A reaction for an unknown message is ignored, not an FK error.
	if err := r.UpsertReaction(ctx, Reaction{MessageID: "ghost", SenderJID: "u@x", Emoji: "👍"}); err != nil {
		t.Fatalf("UpsertReaction(ghost): %v", err)
	}

	rec := Reaction{MessageID: "m1", ChatJID: "chat@s.whatsapp.net", SenderJID: "u@s.whatsapp.net", Emoji: "👍", Timestamp: 10}
	if err := r.UpsertReaction(ctx, rec); err != nil {
		t.Fatalf("UpsertReaction: %v", err)
	}
	// Re-reacting replaces the emoji instead of adding a row.
	rec.Emoji = "❤️"
	rec.Timestamp = 20
	if err := r.UpsertReaction(ctx, rec); err != nil {
		t.Fatalf("UpsertReaction (replace): %v", err)
	}
	got, err := r.ListReactions(ctx, "m1")
	if err != nil {
		t.Fatalf("ListReactions: %v", err)
	}
	if len(got) != 1 || got[0].Emoji != "❤️" || got[0].Timestamp != 20 {
		t.Fatalf("reactions = %+v, want one ❤️ at ts 20", got)
	}

	// An empty emoji deletes the row.
	if err := r.UpsertReaction(ctx, Reaction{MessageID: "m1", SenderJID: "u@s.whatsapp.net", Emoji: ""}); err != nil {
		t.Fatalf("UpsertReaction(remove): %v", err)
	}
	got, err = r.ListReactions(ctx, "m1")
	if err != nil {
		t.Fatalf("ListReactions: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("reactions after remove = %+v, want none", got)
	}
}

func TestWithTxCommitAndRollback(t *testing.T) {
	r, ctx := newTestRepo(t)
	mustChat(t, r, ctx, "chat@s.whatsapp.net")

	if err := r.WithTx(ctx, func(tx *Repo) error {
		_, err := tx.InsertMessage(ctx, Message{ID: "tx1", ChatJID: "chat@s.whatsapp.net", Timestamp: 1})
		return err
	}); err != nil {
		t.Fatalf("WithTx commit: %v", err)
	}
	if _, err := r.GetMessage(ctx, "tx1"); err != nil {
		t.Fatalf("GetMessage(tx1): %v", err)
	}

	// An error inside fn must roll the whole transaction back.
	wantErr := errors.New("boom")
	err := r.WithTx(ctx, func(tx *Repo) error {
		if _, err := tx.InsertMessage(ctx, Message{ID: "tx2", ChatJID: "chat@s.whatsapp.net", Timestamp: 2}); err != nil {
			return err
		}
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("WithTx error = %v, want boom", err)
	}
	if _, err := r.GetMessage(ctx, "tx2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetMessage(tx2) = %v, want ErrNotFound after rollback", err)
	}
}
