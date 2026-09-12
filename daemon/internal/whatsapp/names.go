package whatsapp

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// errNoNameStore is returned when the whatsmeow session store is not available
// (no paired device yet, or the client was deleted). Callers treat it as a
// cacheable miss, never as a fatal error.
var errNoNameStore = errors.New("whatsapp: session store unavailable")

// nameSource is the subset of the whatsmeow client used to resolve display
// names from the local session store. It is implemented by *realClient (which
// reads whatsmeow_contacts / whatsmeow_lid_map through the shared SQLite
// handle) and by the test fakes. Every method is a local, already-cached read:
// resolving a name never performs a network round-trip.
type nameSource interface {
	GetContact(ctx context.Context, user types.JID) (types.ContactInfo, error)
	GetPNForLID(ctx context.Context, lid types.JID) (types.JID, error)
	GetLIDForPN(ctx context.Context, pn types.JID) (types.JID, error)
}

// Cache tuning. Positive results are stable and may live a bit longer; a miss
// is retried soon because a contact/LID mapping may be learned at any moment
// (the message that carries the push name almost always arrives right after
// the chat row is created). The map is bounded so a long-lived daemon cannot
// grow it without limit.
const (
	nameCacheTTL     = 2 * time.Minute
	nameNegativeTTL  = 20 * time.Second
	nameCacheMaxSize = 4096
)

type nameCacheEntry struct {
	name     string
	resolved bool
	expires  time.Time
}

// NameResolver maps a chat JID to a human-readable display name.
//
// Resolution order (a JID is resolved as soon as one step yields a name):
//
//	a. saved contact (cae_contacts, then whatsmeow's contact store);
//	b. for an @lid, the mapped PN's contact (and, for a PN, its @lid contact);
//	c. push name (contact store / persisted cae_contacts, then the live message
//	   hint);
//	d. group subject (cae_groups, populated from GroupInfo events / history);
//	e. fallback: a formatted PN, or the JID itself. An @lid is never returned
//	   when a PN is known.
//
// The optional source is fetched through a closure on every call so a rebuilt
// client (logout + re-pair) is picked up automatically. Resolve is safe to
// call concurrently.
type NameResolver struct {
	source func() nameSource
	logger *slog.Logger

	mu    sync.Mutex
	cache map[string]nameCacheEntry
}

// NewNameResolver builds a resolver. source may be nil (repo-only resolution,
// used by tests and before a device is paired).
func NewNameResolver(source func() nameSource, logger *slog.Logger) *NameResolver {
	if logger == nil {
		logger = slog.Default()
	}
	return &NameResolver{
		source: source,
		logger: logger,
		cache:  make(map[string]nameCacheEntry),
	}
}

// Resolve returns the display name for jidStr and whether it came from a real
// source (contact, LID mapping, push name or group) rather than the fallback.
// The returned name is always non-empty. pushHint is the push name carried by
// the message being persisted, when there is one; a hit is cached only when no
// hint is supplied, so a later message can still improve an unresolved chat.
func (r *NameResolver) Resolve(ctx context.Context, repo *database.Repo, jidStr, pushHint string) (string, bool) {
	if r == nil {
		return fallbackName(jidStr), false
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		if pushHint != "" {
			return pushHint, true
		}
		return jidStr, false
	}

	if pushHint == "" {
		if name, resolved, ok := r.lookup(jidStr); ok {
			return name, resolved
		}
	}

	name, resolved := r.resolve(ctx, repo, jid, pushHint)
	if pushHint == "" {
		r.remember(jidStr, name, resolved)
	}
	return name, resolved
}

// resolve runs the resolution pipeline for one parsed JID.
func (r *NameResolver) resolve(ctx context.Context, repo *database.Repo, jid types.JID, pushHint string) (string, bool) {
	src := r.currentSource()

	// (d) group subject. Network GetGroupInfo is deliberately not used here:
	// the persistence worker would block on it and chats.list could turn into
	// an uncontrolled N+1. cae_groups is fed by GroupInfo events, history sync
	// and the bounded group-name repair (group_repair.go).
	//
	// A group is NEVER named after a participant: the live push hint belongs to
	// the sender, so it is deliberately ignored for @g.us. The chat's own
	// stored name (from history sync / group info) is the next best source; a
	// group with neither cae_groups nor a stored name stays unresolved and the
	// caller must not overwrite the existing value with a fallback.
	if jid.Server == types.GroupServer {
		if repo != nil {
			if g, err := repo.GetGroup(ctx, jid.String()); err == nil && g.Name != "" {
				return g.Name, true
			}
			if c, err := repo.GetChat(ctx, jid.String()); err == nil && chatNameResolved(c.Name, c.JID) {
				return c.Name, true
			}
		}
		return jid.String(), false
	}

	// Candidate identities, most authoritative first: the chat's own JID, then
	// the alternate identity obtained from the LID/PN mapping.
	candidates := []types.JID{jid}
	var pn types.JID
	switch jid.Server {
	case types.HiddenUserServer:
		if src != nil {
			if mapped, err := src.GetPNForLID(ctx, jid); err == nil && !mapped.IsEmpty() {
				pn = mapped
				candidates = append(candidates, mapped)
			}
		}
	case types.DefaultUserServer:
		pn = jid
		if src != nil {
			if mapped, err := src.GetLIDForPN(ctx, jid); err == nil && !mapped.IsEmpty() {
				candidates = append(candidates, mapped)
			}
		}
	}

	// (a)/(b) saved contact names.
	for _, c := range candidates {
		if n := savedContactName(ctx, repo, src, c); n != "" {
			return n, true
		}
	}
	// (c) push names.
	for _, c := range candidates {
		if n := contactPushName(ctx, repo, src, c); n != "" {
			return n, true
		}
	}
	if pushHint != "" {
		return pushHint, true
	}

	// (e) fallback: a formatted phone number when a PN is known, never a raw
	// @lid.
	if !pn.IsEmpty() {
		return formatPhone(pn.User), false
	}
	return jid.String(), false
}

// savedContactName returns FullName/FirstName (or a business name) for jid.
// The daemon's own table is checked first because it is the one the persistence
// path writes to; the whatsmeow store catches contacts that never produced a
// local row.
func savedContactName(ctx context.Context, repo *database.Repo, src nameSource, jid types.JID) string {
	if repo != nil {
		if c, err := repo.GetContact(ctx, jid.String()); err == nil {
			if n := firstNonEmpty(c.FullName, c.FirstName); n != "" {
				return n
			}
		}
	}
	if src != nil {
		if info, err := src.GetContact(ctx, jid); err == nil {
			if n := firstNonEmpty(info.FullName, info.FirstName, info.BusinessName); n != "" {
				return n
			}
		}
	}
	return ""
}

// contactPushName returns the push name known for jid, if any.
func contactPushName(ctx context.Context, repo *database.Repo, src nameSource, jid types.JID) string {
	if repo != nil {
		if c, err := repo.GetContact(ctx, jid.String()); err == nil && c.PushName != "" {
			return c.PushName
		}
	}
	if src != nil {
		if info, err := src.GetContact(ctx, jid); err == nil && info.PushName != "" {
			return info.PushName
		}
	}
	return ""
}

func (r *NameResolver) currentSource() nameSource {
	if r == nil || r.source == nil {
		return nil
	}
	return r.source()
}

func (r *NameResolver) lookup(key string) (string, bool, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.cache[key]
	if !ok || time.Now().After(e.expires) {
		return "", false, false
	}
	return e.name, e.resolved, true
}

func (r *NameResolver) remember(key, name string, resolved bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.cache) >= nameCacheMaxSize {
		r.cache = make(map[string]nameCacheEntry, nameCacheMaxSize)
	}
	ttl := nameCacheTTL
	if !resolved {
		ttl = nameNegativeTTL
	}
	r.cache[key] = nameCacheEntry{name: name, resolved: resolved, expires: time.Now().Add(ttl)}
}

// fallbackName is the last resort when a JID cannot even be parsed: a PN-like
// user part becomes a formatted phone, anything else is returned verbatim.
func fallbackName(jidStr string) string {
	if strings.Contains(jidStr, "@") {
		return jidStr
	}
	return formatPhone(jidStr)
}

// formatPhone renders a PN user part as an E.164 string. Grouping is left to
// the UI; the important property is that it is never an @lid.
func formatPhone(user string) string {
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, user)
	if digits == "" {
		return user
	}
	return "+" + digits
}

// firstNonEmpty returns the first non-empty string.
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// --- realClient implementation of nameSource ---

func (c *realClient) GetContact(ctx context.Context, user types.JID) (types.ContactInfo, error) {
	if c == nil || c.Client == nil || c.Store == nil || c.Store.Contacts == nil {
		return types.ContactInfo{}, errNoNameStore
	}
	return c.Store.Contacts.GetContact(ctx, user)
}

func (c *realClient) GetPNForLID(ctx context.Context, lid types.JID) (types.JID, error) {
	if c == nil || c.Client == nil || c.Store == nil || c.Store.LIDs == nil {
		return types.EmptyJID, errNoNameStore
	}
	return c.Store.LIDs.GetPNForLID(ctx, lid)
}

func (c *realClient) GetLIDForPN(ctx context.Context, pn types.JID) (types.JID, error) {
	if c == nil || c.Client == nil || c.Store == nil || c.Store.LIDs == nil {
		return types.EmptyJID, errNoNameStore
	}
	return c.Store.LIDs.GetLIDForPN(ctx, pn)
}
