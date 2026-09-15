package whatsapp

import (
	"context"
	"log/slog"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/logging"
)

// Group-name repair tuning. The pass runs at most once per interval, touches at
// most groupRepairMaxPerRun groups and waits groupRepairSpacing between network
// queries, so a large account can never flood the server with group-info IQs.
const (
	groupRepairMaxPerRun   = 25
	groupRepairMinInterval = time.Minute
	groupRepairSpacing     = 5 * time.Second
	groupRepairTimeout     = 20 * time.Second
)

// GroupRepairer restores authoritative group subjects after a bad name was
// persisted by an older build (a group had been renamed to the last sender's
// push name). It is a one-time-ish, bounded repair triggered on connect: groups
// that already have an entry in cae_groups are fixed locally from it without
// any network call; the rest are queried with GetGroupInfo at a throttled rate.
type GroupRepairer struct {
	svc    *Service
	repo   *database.Repo
	logger *slog.Logger

	mu      sync.Mutex
	running bool
	lastRun time.Time
}

// NewGroupRepairer builds a repairer over an already-migrated repository.
func NewGroupRepairer(svc *Service, repo *database.Repo, logger *slog.Logger) *GroupRepairer {
	if logger == nil {
		logger = slog.Default()
	}
	return &GroupRepairer{svc: svc, repo: repo, logger: logger}
}

// Kick schedules one repair pass in the background, respecting the minimum
// interval between runs and refusing to run after shutdown.
func (g *GroupRepairer) Kick() {
	if g == nil || g.svc == nil || g.repo == nil {
		return
	}
	g.mu.Lock()
	if g.running || (!g.lastRun.IsZero() && time.Since(g.lastRun) < groupRepairMinInterval) {
		g.mu.Unlock()
		return
	}
	g.running = true
	g.lastRun = time.Now()
	g.mu.Unlock()

	started := g.svc.goTracked(func() {
		defer func() {
			g.mu.Lock()
			g.running = false
			g.mu.Unlock()
		}()
		g.run(g.svc.ctx)
	})
	if !started {
		g.mu.Lock()
		g.running = false
		g.mu.Unlock()
	}
}

// RunOnce performs a repair pass synchronously, ignoring the interval guard.
// It is the test seam for the pass.
func (g *GroupRepairer) RunOnce(ctx context.Context) {
	if g == nil || g.repo == nil {
		return
	}
	g.run(ctx)
}

// run walks every group chat and reconciles its stored name with the
// authoritative subject.
func (g *GroupRepairer) run(ctx context.Context) {
	c := g.client()
	if c == nil {
		return
	}
	chats, err := g.repo.ListChats(ctx, database.MaxListLimit)
	if err != nil {
		g.logger.Warn("whatsapp: group repair list chats failed", slog.String("error", err.Error()))
		return
	}

	queries := 0
	for i := range chats {
		if ctx.Err() != nil {
			return
		}
		ch := chats[i]
		if ch.Kind != "group" || !strings.HasSuffix(ch.JID, "@"+types.GroupServer) {
			continue
		}
		// An authoritative subject already stored locally: reconcile without
		// touching the network.
		if grp, gerr := g.repo.GetGroup(ctx, ch.JID); gerr == nil && grp.Name != "" {
			g.applyName(ctx, ch.JID, grp.Name)
			continue
		}
		if queries >= groupRepairMaxPerRun {
			return
		}
		if queries > 0 {
			select {
			case <-time.After(groupRepairSpacing):
			case <-ctx.Done():
				return
			}
		}
		queries++
		g.fetchAndApply(ctx, c, ch.JID)
	}
}

// fetchAndApply queries GetGroupInfo for one group and persists the subject.
func (g *GroupRepairer) fetchAndApply(ctx context.Context, c fullClient, jid string) {
	parsed, err := types.ParseJID(jid)
	if err != nil {
		return
	}
	fctx, cancel := context.WithTimeout(ctx, groupRepairTimeout)
	defer cancel()
	info, err := c.GetGroupInfo(fctx, parsed)
	if err != nil {
		g.logger.Debug("whatsapp: group repair fetch failed",
			slog.String("jid", logging.RedactJID(jid)),
			slog.String("error", err.Error()))
		return
	}
	if info == nil || info.Name == "" {
		return
	}
	group := database.Group{JID: jid, Name: info.Name}
	if info.Topic != "" {
		group.Topic = info.Topic
	}
	if err := g.repo.UpsertGroup(ctx, group); err != nil {
		g.logger.Warn("whatsapp: group repair upsert group failed",
			slog.String("jid", logging.RedactJID(jid)),
			slog.String("error", err.Error()))
		return
	}
	g.applyName(ctx, jid, group.Name)
}

// applyName persists a group subject into cae_chats and emits chat.updated when
// it actually changed. A participant-like name (empty or the raw JID) is
// ignored so the repair can never introduce a worse value.
func (g *GroupRepairer) applyName(ctx context.Context, jid, name string) {
	if name == "" || name == jid {
		return
	}
	prev, _ := g.repo.GetChat(ctx, jid)
	if prev != nil && prev.Name == name {
		return
	}
	if err := g.repo.UpsertChat(ctx, database.Chat{JID: jid, Kind: "group", Name: name}); err != nil {
		g.logger.Warn("whatsapp: group repair upsert chat failed",
			slog.String("jid", logging.RedactJID(jid)),
			slog.String("error", err.Error()))
		return
	}
	if c, err := g.repo.GetChat(ctx, jid); err == nil {
		g.svc.emit(EventChatUpdated, chatUpdatedData(c))
	}
}

// client returns the current client, or nil when there is no paired/live one.
func (g *GroupRepairer) client() fullClient {
	if g == nil || g.svc == nil {
		return nil
	}
	return g.svc.fullClient()
}

// kickGroupRepair asks the service's repairer (when persistence is enabled) to
// schedule a bounded pass. Called on every successful connection.
func (s *Service) kickGroupRepair() {
	s.mu.RLock()
	r := s.groupRepair
	s.mu.RUnlock()
	if r != nil {
		r.Kick()
	}
}
