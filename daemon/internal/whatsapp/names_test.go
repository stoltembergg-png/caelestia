package whatsapp

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// newNameTest builds a resolver backed by a real temporary database and a fake
// session store.
func newNameTest(t *testing.T) (*NameResolver, *database.Repo, *fakeClient, context.Context) {
	t.Helper()

	db, err := database.Open(filepath.Join(t.TempDir(), "names.db"))
	if err != nil {
		t.Fatalf("database.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	repo := database.NewRepo(db)
	fake := newFakeClient()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	r := NewNameResolver(func() nameSource { return fake }, logger)
	return r, repo, fake, context.Background()
}

func TestNameResolverDirectContact(t *testing.T) {
	r, repo, _, ctx := newNameTest(t)

	if err := repo.UpsertContact(ctx, database.Contact{
		JID:      "alice@s.whatsapp.net",
		FullName: "Alice Wonder",
	}); err != nil {
		t.Fatalf("UpsertContact: %v", err)
	}

	name, resolved := r.Resolve(ctx, repo, "alice@s.whatsapp.net", "")
	if !resolved || name != "Alice Wonder" {
		t.Fatalf("Resolve = %q, %v; want Alice Wonder, true", name, resolved)
	}
}

func TestNameResolverSessionStoreContact(t *testing.T) {
	r, repo, fake, ctx := newNameTest(t)

	pn := types.NewJID("555191078321", types.DefaultUserServer)
	fake.setNameContact(pn, types.ContactInfo{FullName: "Ezequiel Moraes"})

	name, resolved := r.Resolve(ctx, repo, pn.String(), "")
	if !resolved || name != "Ezequiel Moraes" {
		t.Fatalf("Resolve = %q, %v; want Ezequiel Moraes, true", name, resolved)
	}
}

// A LID with only a push name must resolve through the mapped PN's saved
// contact, and must never come back as the raw @lid.
func TestNameResolverLIDToPNContact(t *testing.T) {
	r, repo, fake, ctx := newNameTest(t)

	lid := types.NewJID("181522564960289", types.HiddenUserServer)
	pn := types.NewJID("555197883568", types.DefaultUserServer)
	fake.setLIDMapping(lid, pn)
	fake.setNameContact(lid, types.ContactInfo{PushName: "Luizz"})
	fake.setNameContact(pn, types.ContactInfo{FullName: "Luis Panetone", PushName: "Luizz"})

	name, resolved := r.Resolve(ctx, repo, lid.String(), "")
	if !resolved || name != "Luis Panetone" {
		t.Fatalf("Resolve = %q, %v; want Luis Panetone, true", name, resolved)
	}
	if name == lid.String() {
		t.Fatal("resolver returned the raw @lid")
	}
}

// The inverse direction: a PN whose own contact is unknown falls back to the
// mapped LID's contact.
func TestNameResolverPNToLIDContact(t *testing.T) {
	r, repo, fake, ctx := newNameTest(t)

	lid := types.NewJID("126413906649223", types.HiddenUserServer)
	pn := types.NewJID("554792298655", types.DefaultUserServer)
	fake.setLIDMapping(lid, pn)
	fake.setNameContact(lid, types.ContactInfo{FullName: "Anderson"})

	name, resolved := r.Resolve(ctx, repo, pn.String(), "")
	if !resolved || name != "Anderson" {
		t.Fatalf("Resolve = %q, %v; want Anderson, true", name, resolved)
	}
}

func TestNameResolverPushNameSources(t *testing.T) {
	t.Run("persisted contact push name", func(t *testing.T) {
		r, repo, _, ctx := newNameTest(t)
		if err := repo.UpsertContact(ctx, database.Contact{
			JID:      "bob@s.whatsapp.net",
			PushName: "Bobby",
		}); err != nil {
			t.Fatalf("UpsertContact: %v", err)
		}
		name, resolved := r.Resolve(ctx, repo, "bob@s.whatsapp.net", "")
		if !resolved || name != "Bobby" {
			t.Fatalf("Resolve = %q, %v; want Bobby, true", name, resolved)
		}
	})

	t.Run("session store push name", func(t *testing.T) {
		r, repo, fake, ctx := newNameTest(t)
		pn := types.NewJID("555198931578", types.DefaultUserServer)
		fake.setNameContact(pn, types.ContactInfo{PushName: "DMORAES"})
		name, resolved := r.Resolve(ctx, repo, pn.String(), "")
		if !resolved || name != "DMORAES" {
			t.Fatalf("Resolve = %q, %v; want DMORAES, true", name, resolved)
		}
	})

	t.Run("live message hint", func(t *testing.T) {
		r, repo, _, ctx := newNameTest(t)
		name, resolved := r.Resolve(ctx, repo, "carol@s.whatsapp.net", "Carol Push")
		if !resolved || name != "Carol Push" {
			t.Fatalf("Resolve = %q, %v; want Carol Push, true", name, resolved)
		}
	})
}

func TestNameResolverGroup(t *testing.T) {
	r, repo, _, ctx := newNameTest(t)

	if err := repo.UpsertGroup(ctx, database.Group{JID: "g@g.us", Name: "The Group"}); err != nil {
		t.Fatalf("UpsertGroup: %v", err)
	}
	name, resolved := r.Resolve(ctx, repo, "g@g.us", "")
	if !resolved || name != "The Group" {
		t.Fatalf("Resolve = %q, %v; want The Group, true", name, resolved)
	}
}

func TestNameResolverFallbacks(t *testing.T) {
	t.Run("pn without any name", func(t *testing.T) {
		r, repo, _, ctx := newNameTest(t)
		name, resolved := r.Resolve(ctx, repo, "13135550002@s.whatsapp.net", "")
		if resolved {
			t.Fatalf("resolved = true, want false for a nameless PN")
		}
		if name != "+13135550002" {
			t.Fatalf("name = %q, want +13135550002", name)
		}
	})

	t.Run("lid with a known pn", func(t *testing.T) {
		r, repo, fake, ctx := newNameTest(t)
		lid := types.NewJID("46480303902780", types.HiddenUserServer)
		pn := types.NewJID("555198957882", types.DefaultUserServer)
		fake.setLIDMapping(lid, pn)

		name, resolved := r.Resolve(ctx, repo, lid.String(), "")
		if resolved {
			t.Fatalf("resolved = true, want false (only a fallback exists)")
		}
		if name != "+555198957882" {
			t.Fatalf("name = %q, want +555198957882 (never the raw @lid)", name)
		}
	})

	t.Run("lid with no mapping", func(t *testing.T) {
		r, repo, _, ctx := newNameTest(t)
		lid := types.NewJID("99999999999999", types.HiddenUserServer)
		name, resolved := r.Resolve(ctx, repo, lid.String(), "")
		if resolved {
			t.Fatalf("resolved = true, want false")
		}
		if name != lid.String() {
			t.Fatalf("name = %q, want %q", name, lid.String())
		}
	})
}

func TestNameResolverCachesResults(t *testing.T) {
	r, repo, fake, ctx := newNameTest(t)

	pn := types.NewJID("555191078321", types.DefaultUserServer)
	fake.setNameContact(pn, types.ContactInfo{FullName: "Ezequiel Moraes"})

	if _, _ = r.Resolve(ctx, repo, pn.String(), ""); fake.nameReadCount() == 0 {
		t.Fatal("first resolve performed no store read")
	}
	reads := fake.nameReadCount()
	if _, _ = r.Resolve(ctx, repo, pn.String(), ""); fake.nameReadCount() != reads {
		t.Fatalf("second resolve hit the store: %d -> %d", reads, fake.nameReadCount())
	}
}

// --- chats.list lazy backfill ---

func TestChatsListBackfillsResolvedNames(t *testing.T) {
	m, svc, fake, repo, ctx := newTestMethods(t)

	lid := types.NewJID("181522564960289", types.HiddenUserServer)
	pn := types.NewJID("555197883568", types.DefaultUserServer)
	fake.setLIDMapping(lid, pn)
	fake.setNameContact(pn, types.ContactInfo{FullName: "Luis Panetone"})

	// The chat row exists with the raw @lid as its name (what the old daemon
	// effectively displayed). It must be replaced by the resolved name.
	if err := repo.UpsertChat(ctx, database.Chat{JID: lid.String(), Kind: "dm", Name: lid.String()}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}

	got, ipcErr := m.ChatsList(ctx, json.RawMessage(`{"limit":10}`))
	if ipcErr != nil {
		t.Fatalf("ChatsList: %v", ipcErr)
	}
	chats, ok := got.([]map[string]any)
	if !ok || len(chats) != 1 {
		t.Fatalf("result = %#v, want one chat", got)
	}
	if chats[0]["name"] != "Luis Panetone" {
		t.Fatalf("display name = %v, want Luis Panetone", chats[0]["name"])
	}

	c, err := repo.GetChat(ctx, lid.String())
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if c.Name != "Luis Panetone" {
		t.Fatalf("persisted name = %q, want Luis Panetone", c.Name)
	}

	// chat.updated must have been emitted with the new name.
	select {
	case ev := <-svc.Events():
		if ev.Name != EventChatUpdated {
			t.Fatalf("event = %q, want %q", ev.Name, EventChatUpdated)
		}
		if ev.Data["jid"] != lid.String() || ev.Data["name"] != "Luis Panetone" {
			t.Fatalf("event data = %#v", ev.Data)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no chat.updated emitted for the backfilled name")
	}
}

func TestChatsListFallbackNotPersisted(t *testing.T) {
	m, _, fake, repo, ctx := newTestMethods(t)

	pn := types.NewJID("13135550002", types.DefaultUserServer)
	fake.setNameContact(pn, types.ContactInfo{}) // present but nameless
	if err := repo.UpsertChat(ctx, database.Chat{JID: pn.String(), Kind: "dm"}); err != nil {
		t.Fatalf("UpsertChat: %v", err)
	}

	got, ipcErr := m.ChatsList(ctx, json.RawMessage(`{"limit":10}`))
	if ipcErr != nil {
		t.Fatalf("ChatsList: %v", ipcErr)
	}
	chats, ok := got.([]map[string]any)
	if !ok || len(chats) != 1 {
		t.Fatalf("result = %#v, want one chat", got)
	}
	if chats[0]["name"] != "+13135550002" {
		t.Fatalf("display name = %v, want +13135550002", chats[0]["name"])
	}

	c, err := repo.GetChat(ctx, pn.String())
	if err != nil {
		t.Fatalf("GetChat: %v", err)
	}
	if c.Name != "" {
		t.Fatalf("fallback was persisted as a name: %q", c.Name)
	}
}
