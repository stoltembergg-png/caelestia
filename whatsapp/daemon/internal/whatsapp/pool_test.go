package whatsapp

import (
	"context"
	"path/filepath"
	"testing"

	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// TestSharedPoolForeignKeysAndDeviceLifecycle guards the invariant that the
// cae_* repo and the whatsmeow sqlstore can share one *sql.DB: sqlstore.Upgrade
// refuses to run unless foreign keys are enabled, and creating/deleting a
// device must work on that same pool without turning FK enforcement off.
func TestSharedPoolForeignKeysAndDeviceLifecycle(t *testing.T) {
	db, err := database.Open(filepath.Join(t.TempDir(), "whatsapp.db"))
	if err != nil {
		t.Fatalf("database.Open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()

	assertForeignKeysOn := func(when string) {
		t.Helper()
		var fk int
		if err := db.QueryRow("PRAGMA foreign_keys").Scan(&fk); err != nil {
			t.Fatalf("PRAGMA foreign_keys (%s): %v", when, err)
		}
		if fk != 1 {
			t.Fatalf("foreign_keys = %d (%s), want 1", fk, when)
		}
	}
	assertForeignKeysOn("before sqlstore")

	// Upgrade runs the whatsmeow_* migrations on the very same pool and, for
	// SQLite, fails unless foreign keys are on.
	container := sqlstore.NewWithDB(db, database.DriverName, waLog.Noop)
	if err := container.Upgrade(ctx); err != nil {
		t.Fatalf("sqlstore.Upgrade on shared pool: %v", err)
	}
	assertForeignKeysOn("after sqlstore.Upgrade")

	// Create a device through the sqlstore on the shared pool.
	jid := types.NewJID("15551234567", types.DefaultUserServer)
	device := container.NewDevice()
	device.ID = &jid
	// whatsmeow_device has NOT NULL (and length-checked) signature columns, so
	// fill them with placeholder values of the right size.
	device.Account = &waAdv.ADVSignedDeviceIdentity{
		Details:             []byte{},
		AccountSignature:    make([]byte, 64),
		AccountSignatureKey: make([]byte, 32),
		DeviceSignature:     make([]byte, 64),
	}
	if err := container.PutDevice(ctx, device); err != nil {
		t.Fatalf("PutDevice: %v", err)
	}
	got, err := container.GetDevice(ctx, jid)
	if err != nil {
		t.Fatalf("GetDevice: %v", err)
	}
	if got == nil {
		t.Fatal("GetDevice returned nil after PutDevice")
	}

	// Delete it again.
	if err := container.DeleteDevice(ctx, device); err != nil {
		t.Fatalf("DeleteDevice: %v", err)
	}
	got, err = container.GetDevice(ctx, jid)
	if err != nil {
		t.Fatalf("GetDevice(after delete): %v", err)
	}
	if got != nil {
		t.Fatalf("device still present after DeleteDevice: %+v", got)
	}
	assertForeignKeysOn("after device lifecycle")

	// The cae_* foreign keys are still enforced on the shared pool.
	if _, err := db.Exec(
		`INSERT INTO cae_messages (id, chat_jid, timestamp) VALUES ('m1', 'missing@s.whatsapp.net', 1)`,
	); err == nil {
		t.Fatal("insert with dangling chat_jid succeeded, want foreign key violation on shared pool")
	}
}
