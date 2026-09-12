package whatsapp

import (
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// groupTestMessage builds an incoming group message whose sender has a push
// name different from the group subject.
func groupTestMessage(id, groupJID, senderJID, pushName string) *events.Message {
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:    mustJID(groupJID),
				Sender:  mustJID(senderJID),
				IsGroup: true,
			},
			ID:        id,
			Timestamp: time.UnixMilli(1),
			PushName:  pushName,
		},
		Message: &waE2E.Message{Conversation: proto.String("oi")},
	}
}

// TestPersistGroupMessageDoesNotRenameChat is the regression test for the bug:
// a group message from "Fábio" must not rename the group to "Fábio".
func TestPersistGroupMessageDoesNotRenameChat(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const group = "120363266949937159@g.us"

	if err := repo.UpsertChat(ctx, database.Chat{JID: group, Kind: "group", Name: "Grupo Certo"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if err := p.persistMessage(ctx, groupTestMessage("m1", group, "5511999999999@s.whatsapp.net", "Fábio")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}

	chat, err := repo.GetChat(ctx, group)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Grupo Certo" {
		t.Fatalf("group name = %q, want %q (sender push name leaked into the chat)", chat.Name, "Grupo Certo")
	}
	// The participant's push name is still recorded as a contact, just not as
	// the chat name.
	contact, err := repo.GetContact(ctx, "5511999999999@s.whatsapp.net")
	if err != nil {
		t.Fatalf("GetContact: %v", err)
	}
	if contact.PushName != "Fábio" {
		t.Fatalf("participant push name = %q, want Fábio", contact.PushName)
	}
}

// TestPersistGroupMessageFirstTimeKeepsUnresolvedName verifies a brand-new group
// with no subject yet is not named after the sender: the name stays empty so a
// later group-info subject can fill it.
func TestPersistGroupMessageFirstTimeKeepsUnresolvedName(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const group = "120363266949937159@g.us"

	if err := p.persistMessage(ctx, groupTestMessage("m1", group, "5511999999999@s.whatsapp.net", "Fábio")); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	chat, err := repo.GetChat(ctx, group)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name == "Fábio" {
		t.Fatalf("new group was named after its sender: %q", chat.Name)
	}
}

// TestResolveGroupUsesAuthoritativeSources covers the resolver directly.
func TestResolveGroupUsesAuthoritativeSources(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const group = "120363266949937159@g.us"

	// No cae_groups and no chat row: unresolved, never the push hint.
	name, resolved := p.svc.nameResolver().Resolve(ctx, repo, group, "Fábio")
	if resolved || name == "Fábio" {
		t.Fatalf("resolve without source = (%q,%v), want unresolved and never Fábio", name, resolved)
	}

	// Stored chat name (history sync / group info) wins over the push hint.
	if err := repo.UpsertChat(ctx, database.Chat{JID: group, Kind: "group", Name: "Grupo Certo"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	name, resolved = p.svc.nameResolver().Resolve(ctx, repo, group, "Fábio")
	if !resolved || name != "Grupo Certo" {
		t.Fatalf("resolve with chat row = (%q,%v), want (Grupo Certo,true)", name, resolved)
	}

	// cae_groups is the most authoritative.
	if err := repo.UpsertGroup(ctx, database.Group{JID: group, Name: "Grupo Real"}); err != nil {
		t.Fatalf("UpsertGroup: %v", err)
	}
	name, resolved = p.svc.nameResolver().Resolve(ctx, repo, group, "Fábio")
	if !resolved || name != "Grupo Real" {
		t.Fatalf("resolve with group row = (%q,%v), want (Grupo Real,true)", name, resolved)
	}
}

// TestPersistDMMessageStillResolvesName guards the 1:1 path against regression.
func TestPersistDMMessageStillResolvesName(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const dm = "5511999999999@s.whatsapp.net"

	ev := testMessage("m1", dm, dm, false, 1, "oi")
	ev.Info.PushName = "Bob"
	if err := p.persistMessage(ctx, ev); err != nil {
		t.Fatalf("persistMessage: %v", err)
	}
	chat, err := repo.GetChat(ctx, dm)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Bob" {
		t.Fatalf("dm name = %q, want Bob (1:1 push name must still resolve)", chat.Name)
	}
}

// TestPersistGroupInfoUpdatesChatName verifies GroupInfo is authoritative.
func TestPersistGroupInfoUpdatesChatName(t *testing.T) {
	p, repo, ctx := newTestPersister(t)
	const group = "120363266949937159@g.us"

	if err := repo.UpsertChat(ctx, database.Chat{JID: group, Kind: "group", Name: "Fábio"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	err := p.persistGroup(ctx, &events.GroupInfo{
		JID:  mustJID(group),
		Name: &types.GroupName{Name: "Grupo Real"},
	})
	if err != nil {
		t.Fatalf("persistGroup: %v", err)
	}
	chat, err := repo.GetChat(ctx, group)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Grupo Real" {
		t.Fatalf("chat name = %q, want Grupo Real", chat.Name)
	}
	grp, err := repo.GetGroup(ctx, group)
	if err != nil {
		t.Fatalf("GetGroup: %v", err)
	}
	if grp.Name != "Grupo Real" {
		t.Fatalf("group name = %q, want Grupo Real", grp.Name)
	}
}

// TestGroupRepairFetchesAndPersistsSubject verifies the data-repair pass.
func TestGroupRepairFetchesAndPersistsSubject(t *testing.T) {
	_, svc, mf, repo, ctx := newTestMethods(t)
	const group = "120363266949937159@g.us"
	const dm = "5511999999999@s.whatsapp.net"

	if err := repo.UpsertChat(ctx, database.Chat{JID: group, Kind: "group", Name: "Fábio"}); err != nil {
		t.Fatalf("UpsertChat group: %v", err)
	}
	if err := repo.UpsertChat(ctx, database.Chat{JID: dm, Kind: "dm", Name: "Bob"}); err != nil {
		t.Fatalf("UpsertChat dm: %v", err)
	}
	mf.groupInfo[group] = &types.GroupInfo{
		JID:       mustJID(group),
		GroupName: types.GroupName{Name: "Grupo Real"},
	}

	r := NewGroupRepairer(svc, repo, nil)
	r.RunOnce(ctx)

	chat, err := repo.GetChat(ctx, group)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "Grupo Real" {
		t.Fatalf("repaired group name = %q, want Grupo Real", chat.Name)
	}
	grp, err := repo.GetGroup(ctx, group)
	if err != nil {
		t.Fatalf("GetGroup: %v", err)
	}
	if grp.Name != "Grupo Real" {
		t.Fatalf("cae_groups name = %q, want Grupo Real", grp.Name)
	}
	if n := mf.groupCallCount(); n != 1 {
		t.Fatalf("GetGroupInfo calls = %d, want 1 (DM must be skipped)", n)
	}
	if got, err := repo.GetChat(ctx, dm); err != nil || got.Name != "Bob" {
		t.Fatalf("dm was modified: %+v (%v)", got, err)
	}
	// The repair announces the change.
	ev := readEvent(t, svc.Events(), EventChatUpdated)
	if ev.Data["jid"] != group || ev.Data["name"] != "Grupo Real" {
		t.Fatalf("chat.updated = %#v", ev.Data)
	}
}

// TestGroupRepairUsesLocalGroupNameWithoutNetwork verifies a group that already
// has an authoritative cae_groups row is reconciled locally, with no IQ.
func TestGroupRepairUsesLocalGroupNameWithoutNetwork(t *testing.T) {
	_, svc, mf, repo, ctx := newTestMethods(t)
	const group = "120363370685533356@g.us"

	if err := repo.UpsertChat(ctx, database.Chat{JID: group, Kind: "group", Name: "Fábio"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}
	if err := repo.UpsertGroup(ctx, database.Group{JID: group, Name: "SÓ RESENHA"}); err != nil {
		t.Fatalf("UpsertGroup: %v", err)
	}

	r := NewGroupRepairer(svc, repo, nil)
	r.RunOnce(ctx)

	chat, err := repo.GetChat(ctx, group)
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if chat.Name != "SÓ RESENHA" {
		t.Fatalf("chat name = %q, want SÓ RESENHA", chat.Name)
	}
	if n := mf.groupCallCount(); n != 0 {
		t.Fatalf("GetGroupInfo calls = %d, want 0", n)
	}
}
