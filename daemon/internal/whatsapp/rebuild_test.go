package whatsapp

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// openTestRepo opens a throwaway repository for tests that need persistence.
func openTestRepo(t *testing.T) (*database.Repo, context.Context) {
	t.Helper()
	db, err := database.Open(filepath.Join(t.TempDir(), "whatsapp.db"))
	if err != nil {
		t.Fatalf("database.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return database.NewRepo(db), context.Background()
}

// TestPersistenceReattachedAfterRebuild reproduces the reported bug: after a
// logout the client is rebuilt from a fresh device, and the persistence handler
// (and the state handler) must be re-registered on the new client.
func TestPersistenceReattachedAfterRebuild(t *testing.T) {
	base := newFakeClient()
	svc, _ := newTestService(t, base)
	repo, _ := openTestRepo(t)

	p := svc.EnablePersistence(repo, t.TempDir())
	t.Cleanup(p.Close)

	if got := base.handlerCount(); got != 2 {
		t.Fatalf("initial client handlers = %d, want 2 (state + persistence)", got)
	}

	// Simulate logout + re-pair: rebuildClient builds a brand new client.
	var newClient *fakeClient
	svc.clientFactory = func(*store.Device, waLog.Logger) waClient {
		newClient = newFakeClient()
		return newClient
	}
	svc.firstDevice = func(context.Context) (*store.Device, error) {
		return &store.Device{}, nil
	}
	if err := svc.rebuildClient(context.Background()); err != nil {
		t.Fatalf("rebuildClient: %v", err)
	}
	if newClient == nil {
		t.Fatal("rebuildClient did not create a new client")
	}
	if got := newClient.handlerCount(); got != 2 {
		t.Fatalf("rebuilt client handlers = %d, want 2 (state + persistence)", got)
	}

	// A message delivered to the new client must still reach SQLite, which
	// only happens when the persistence handler was re-attached.
	msg := testMessage("after-rebuild", "rebuilt@s.whatsapp.net", "rebuilt@s.whatsapp.net", false, 5000, "survived")
	newClient.dispatchEvent(msg)

	deadline := time.Now().Add(2 * time.Second)
	for {
		msgs, err := repo.ListMessages(context.Background(), "rebuilt@s.whatsapp.net", 10, 0)
		if err != nil {
			t.Fatalf("ListMessages: %v", err)
		}
		if len(msgs) == 1 && msgs[0].ID == "after-rebuild" {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("message was not persisted after rebuild: %+v", msgs)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestHandlersAttachedBeforeConnect asserts the ordering invariant: every
// handler (state + persistence) is registered before Connect is invoked,
// including on the automatic boot path via Service.Start.
func TestHandlersAttachedBeforeConnect(t *testing.T) {
	base := newFakeClient()
	svc, _ := newTestService(t, base)
	repo, _ := openTestRepo(t)

	p := svc.EnablePersistence(repo, t.TempDir())
	t.Cleanup(p.Close)

	jid := types.NewJID("5511999999999", types.DefaultUserServer)
	setDevice(svc, &store.Device{ID: &jid})

	if err := svc.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		called, handlersAtConnect := base.connectInfo()
		if called {
			if handlersAtConnect != 2 {
				t.Fatalf("handlers registered at Connect = %d, want 2 (state + persistence)", handlersAtConnect)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("Start did not trigger a connection")
		}
		time.Sleep(5 * time.Millisecond)
	}
}
