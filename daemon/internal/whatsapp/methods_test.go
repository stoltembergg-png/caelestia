package whatsapp

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/ipc"
)

// methodFake extends fakeClient with the outbound/parse/media surface required
// by the fullClient interface.
type methodFake struct {
	*fakeClient

	sendResp  whatsmeow.SendResponse
	sendErr   error
	sentTo    types.JID
	sentMsg   *waE2E.Message
	markCalls int
	markErr   error

	avatarInfo  *types.ProfilePictureInfo
	avatarErr   error
	avatarCalls int

	downloadData []byte
	downloadErr  error

	uploadResp whatsmeow.UploadResponse
	uploadErr  error
	uploadApp  whatsmeow.MediaType
	uploadRead int64

	groupInfo  map[string]*types.GroupInfo
	groupErr   error
	groupCalls int
}

func (f *methodFake) SendMessage(_ context.Context, to types.JID, message *waE2E.Message, _ ...whatsmeow.SendRequestExtra) (whatsmeow.SendResponse, error) {
	f.sentTo = to
	f.sentMsg = message
	return f.sendResp, f.sendErr
}

func (f *methodFake) MarkRead(_ context.Context, _ []types.MessageID, _ time.Time, _, _ types.JID, _ ...types.ReceiptType) error {
	f.markCalls++
	return f.markErr
}

func (f *methodFake) ParseWebMessage(types.JID, *waWeb.WebMessageInfo) (*events.Message, error) {
	return nil, errors.New("not implemented in fake")
}

func (f *methodFake) GetProfilePictureInfo(_ context.Context, _ types.JID, _ *whatsmeow.GetProfilePictureParams) (*types.ProfilePictureInfo, error) {
	f.mu.Lock()
	f.avatarCalls++
	f.mu.Unlock()
	return f.avatarInfo, f.avatarErr
}

// avatarCallCount returns how many profile-picture lookups the fake served.
func (f *methodFake) avatarCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.avatarCalls
}

func (f *methodFake) DownloadToFile(_ context.Context, _ whatsmeow.DownloadableMessage, file whatsmeow.File) error {
	if f.downloadErr != nil {
		return f.downloadErr
	}
	_, err := file.Write(f.downloadData)
	return err
}

func (f *methodFake) UploadReader(_ context.Context, plaintext io.Reader, _ io.ReadWriteSeeker, appInfo whatsmeow.MediaType) (whatsmeow.UploadResponse, error) {
	f.mu.Lock()
	f.uploadApp = appInfo
	f.mu.Unlock()
	if f.uploadErr != nil {
		return whatsmeow.UploadResponse{}, f.uploadErr
	}
	// Drain the plaintext so the counting progressReader is exercised.
	n, _ := io.Copy(io.Discard, plaintext)
	f.mu.Lock()
	f.uploadRead = n
	f.mu.Unlock()
	return f.uploadResp, nil
}

func (f *methodFake) GetGroupInfo(_ context.Context, jid types.JID) (*types.GroupInfo, error) {
	f.mu.Lock()
	f.groupCalls++
	info := f.groupInfo[jid.String()]
	f.mu.Unlock()
	if f.groupErr != nil {
		return nil, f.groupErr
	}
	return info, nil
}

// groupCallCount returns how many GetGroupInfo calls the fake served.
func (f *methodFake) groupCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.groupCalls
}

func (f *methodFake) BuildReaction(chat, sender types.JID, id types.MessageID, reaction string) *waE2E.Message {
	return &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{
		Key: &waCommon.MessageKey{
			RemoteJID:   proto.String(chat.String()),
			FromMe:      proto.Bool(true),
			ID:          proto.String(string(id)),
			Participant: proto.String(sender.String()),
		},
		Text: proto.String(reaction),
	}}
}

func newTestMethods(t *testing.T) (*Methods, *Service, *methodFake, *database.Repo, context.Context) {
	t.Helper()

	base := newFakeClient()
	svc, _ := newTestService(t, base)
	mf := &methodFake{fakeClient: base, sendResp: whatsmeow.SendResponse{
		ID:        types.MessageID("server-id-1"),
		Timestamp: time.UnixMilli(1700000000000),
	}, uploadResp: whatsmeow.UploadResponse{
		URL:           "https://mmg.whatsapp.net/d/f/abc",
		DirectPath:    "/v/t62.7118-24/abc",
		MediaKey:      make([]byte, 32),
		FileSHA256:    make([]byte, 32),
		FileEncSHA256: make([]byte, 32),
		FileLength:    4,
	}, groupInfo: make(map[string]*types.GroupInfo)}
	svc.mu.Lock()
	svc.client = mf
	svc.mu.Unlock()

	jid := types.NewJID("5511999999999", types.DefaultUserServer)
	setDevice(svc, &store.Device{ID: &jid})

	dir := t.TempDir()
	db, err := database.Open(filepath.Join(dir, "whatsapp.db"))
	if err != nil {
		t.Fatalf("database.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	repo := database.NewRepo(db)

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return NewMethods(svc, repo, dir, logger), svc, mf, repo, context.Background()
}

func TestChatsListReturnsOrderedData(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)

	if err := repo.UpsertChat(ctx, database.Chat{JID: "b@s.whatsapp.net", Name: "B"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if err := repo.UpsertChat(ctx, database.Chat{JID: "a@s.whatsapp.net", Name: "A"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if err := repo.UpdateChatLastMessage(ctx, "a@s.whatsapp.net", "m1", 200, "newer"); err != nil {
		t.Fatalf("UpdateChatLastMessage: %v", err)
	}
	if err := repo.UpdateChatLastMessage(ctx, "b@s.whatsapp.net", "m2", 100, "older"); err != nil {
		t.Fatalf("UpdateChatLastMessage: %v", err)
	}
	if err := repo.SetUnread(ctx, "a@s.whatsapp.net", 3); err != nil {
		t.Fatalf("SetUnread: %v", err)
	}

	got, ipcErr := m.ChatsList(ctx, json.RawMessage(`{"limit":10}`))
	if ipcErr != nil {
		t.Fatalf("ChatsList: %v", ipcErr)
	}
	chats, ok := got.([]map[string]any)
	if !ok || len(chats) != 2 {
		t.Fatalf("result = %#v, want 2 chats", got)
	}
	if chats[0]["jid"] != "a@s.whatsapp.net" || chats[0]["name"] != "A" {
		t.Fatalf("first chat = %#v, want a/A", chats[0])
	}
	if chats[0]["lastMessage"] != "newer" || chats[0]["unread"] != 3 {
		t.Fatalf("first chat fields = %#v", chats[0])
	}
	if chats[0]["timestamp"] != ipc.StringTimestamp(200) {
		t.Fatalf("timestamp = %v, want %v", chats[0]["timestamp"], ipc.StringTimestamp(200))
	}
}

func TestChatsListNotPaired(t *testing.T) {
	m, svc, _, _, ctx := newTestMethods(t)
	setDevice(svc, &store.Device{}) // drop the paired session

	if _, ipcErr := m.ChatsList(ctx, nil); ipcErr == nil || ipcErr.Code != CodeNotPaired {
		t.Fatalf("error = %v, want %s", ipcErr, CodeNotPaired)
	}
}

func TestChatMessagesReturnsNewestFirst(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)

	if err := repo.UpsertChat(ctx, database.Chat{JID: "a@s.whatsapp.net"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	for i, ts := range []int64{100, 200, 300} {
		id := []string{"m1", "m2", "m3"}[i]
		if _, err := repo.InsertMessage(ctx, database.Message{ID: id, ChatJID: "a@s.whatsapp.net", Timestamp: ts, Type: "text", Text: id}); err != nil {
			t.Fatalf("InsertMessage: %v", err)
		}
	}

	got, ipcErr := m.ChatMessages(ctx, json.RawMessage(`{"jid":"a@s.whatsapp.net","limit":2}`))
	if ipcErr != nil {
		t.Fatalf("ChatMessages: %v", ipcErr)
	}
	msgs, ok := got.([]map[string]any)
	if !ok || len(msgs) != 2 {
		t.Fatalf("result = %#v, want 2 messages", got)
	}
	if msgs[0]["id"] != "m3" || msgs[1]["id"] != "m2" {
		t.Fatalf("order = %v, %v; want m3, m2", msgs[0]["id"], msgs[1]["id"])
	}
}

func TestChatOpenNotFound(t *testing.T) {
	m, _, _, _, ctx := newTestMethods(t)

	if _, ipcErr := m.ChatOpen(ctx, json.RawMessage(`{"jid":"nope@s.whatsapp.net"}`)); ipcErr == nil || ipcErr.Code != CodeNotFound {
		t.Fatalf("error = %v, want %s", ipcErr, CodeNotFound)
	}
}

func TestContactsSearch(t *testing.T) {
	m, _, _, repo, ctx := newTestMethods(t)

	if err := repo.UpsertContact(ctx, database.Contact{JID: "alice@s.whatsapp.net", FullName: "Alice Wonder"}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}
	got, ipcErr := m.ContactsSearch(ctx, json.RawMessage(`{"query":"alice","limit":10}`))
	if ipcErr != nil {
		t.Fatalf("ContactsSearch: %v", ipcErr)
	}
	list, ok := got.([]map[string]any)
	if !ok || len(list) != 1 || list[0]["name"] != "Alice Wonder" {
		t.Fatalf("result = %#v, want Alice Wonder", got)
	}
}

func TestMessageSendPersistsAndReturnsID(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)

	got, ipcErr := m.MessageSend(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net","text":"hello"}`))
	if ipcErr != nil {
		t.Fatalf("MessageSend: %v", ipcErr)
	}
	res, ok := got.(map[string]any)
	if !ok {
		t.Fatalf("result = %#v", got)
	}
	if res["id"] != "server-id-1" || res["timestamp"] != ipc.StringTimestamp(1700000000000) {
		t.Fatalf("result = %#v, want id/timestamp", res)
	}
	if mf.sentTo.String() != "bob@s.whatsapp.net" {
		t.Fatalf("sentTo = %q", mf.sentTo)
	}
	if mf.sentMsg.GetConversation() != "hello" {
		t.Fatalf("message text = %q", mf.sentMsg.GetConversation())
	}

	msg, err := repo.GetMessage(ctx, "server-id-1")
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if !msg.FromMe || msg.Text != "hello" {
		t.Fatalf("stored message = %+v", msg)
	}
}

func TestMessageSendValidationAndFailure(t *testing.T) {
	m, _, mf, _, ctx := newTestMethods(t)

	if _, ipcErr := m.MessageSend(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net","text":"  "}`)); ipcErr == nil || ipcErr.Code != CodeInvalidRequest {
		t.Fatalf("empty text error = %v, want %s", ipcErr, CodeInvalidRequest)
	}
	if _, ipcErr := m.MessageSend(ctx, json.RawMessage(`{"jid":"not a jid","text":"hi"}`)); ipcErr == nil || ipcErr.Code != CodeInvalidRequest {
		t.Fatalf("bad jid error = %v, want %s", ipcErr, CodeInvalidRequest)
	}

	mf.sendErr = errors.New("boom")
	if _, ipcErr := m.MessageSend(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net","text":"hi"}`)); ipcErr == nil || ipcErr.Code != CodeSendFailed {
		t.Fatalf("send failure error = %v, want %s", ipcErr, CodeSendFailed)
	}
}

func TestMessageReplyBuildsQuotedContext(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)

	// The quoted message exists so its sender is used as the participant.
	if err := repo.UpsertChat(ctx, database.Chat{JID: "bob@s.whatsapp.net"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{
		ID: "quoted-1", ChatJID: "bob@s.whatsapp.net", SenderJID: "bob@s.whatsapp.net", Timestamp: 1,
	}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}

	if _, ipcErr := m.MessageReply(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net","id":"quoted-1","text":"reply"}`)); ipcErr != nil {
		t.Fatalf("MessageReply: %v", ipcErr)
	}
	et := mf.sentMsg.GetExtendedTextMessage()
	if et == nil || et.GetText() != "reply" {
		t.Fatalf("extended text = %+v", et)
	}
	ci := et.GetContextInfo()
	if ci == nil || ci.GetStanzaID() != "quoted-1" || ci.GetParticipant() != "bob@s.whatsapp.net" {
		t.Fatalf("context info = %+v", ci)
	}
}

func TestMessageReadMarksPending(t *testing.T) {
	m, _, mf, repo, ctx := newTestMethods(t)

	if err := repo.UpsertChat(ctx, database.Chat{JID: "bob@s.whatsapp.net"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if _, err := repo.InsertMessage(ctx, database.Message{
		ID: "in1", ChatJID: "bob@s.whatsapp.net", SenderJID: "bob@s.whatsapp.net", Timestamp: 1,
	}); err != nil {
		t.Fatalf("InsertMessage: %v", err)
	}
	if err := repo.IncrementUnread(ctx, "bob@s.whatsapp.net"); err != nil {
		t.Fatalf("IncrementUnread: %v", err)
	}

	got, ipcErr := m.MessageRead(ctx, json.RawMessage(`{"jid":"bob@s.whatsapp.net"}`))
	if ipcErr != nil {
		t.Fatalf("MessageRead: %v", ipcErr)
	}
	if res, ok := got.(map[string]any); !ok || res["read"] != 1 {
		t.Fatalf("result = %#v, want read=1", got)
	}
	if mf.markCalls != 1 {
		t.Fatalf("MarkRead calls = %d, want 1", mf.markCalls)
	}
	chat, err := repo.GetChat(ctx, "bob@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.UnreadCount != 0 {
		t.Fatalf("unread = %d, want 0", chat.UnreadCount)
	}
}
