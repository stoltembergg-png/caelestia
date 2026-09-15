package whatsapp

import (
	"context"
	"log/slog"
	"sync"

	"github.com/stoltembergg-png/caelestia-whatsapp/daemon/internal/database"
)

// ThumbRepairMaxPerRun bounds one backfill pass. The pass is local-only (it
// reads the proto already stored in cae_media and writes a file), so this is
// just a guard against a huge burst of disk writes at startup.
const ThumbRepairMaxPerRun = 1000

// ThumbRepairer materializes the embedded thumbnails of media rows persisted
// before thumbnails were extracted at persistence time. It runs one bounded
// pass at startup: for every cae_media row of a thumbnail-capable kind that has
// a proto but no thumb_path, it writes thumbnails/<sha256>.jpg and stores the
// path. No network access is involved.
type ThumbRepairer struct {
	svc      *Service
	repo     *database.Repo
	thumbDir string
	logger   *slog.Logger

	mu      sync.Mutex
	running bool
	done    bool
}

// NewThumbRepairer builds a repairer. An empty thumbDir disables it.
func NewThumbRepairer(svc *Service, repo *database.Repo, thumbDir string, logger *slog.Logger) *ThumbRepairer {
	if logger == nil {
		logger = slog.Default()
	}
	return &ThumbRepairer{svc: svc, repo: repo, thumbDir: thumbDir, logger: logger}
}

// Kick schedules the one-shot backfill pass in the background. Later calls are
// no-ops after a pass has run.
func (t *ThumbRepairer) Kick() {
	if t == nil || t.svc == nil || t.repo == nil || t.thumbDir == "" {
		return
	}
	t.mu.Lock()
	if t.running || t.done {
		t.mu.Unlock()
		return
	}
	t.running = true
	t.mu.Unlock()

	started := t.svc.goTracked(func() {
		defer func() {
			t.mu.Lock()
			t.running = false
			t.done = true
			t.mu.Unlock()
		}()
		t.RunOnce(t.svc.ctx)
	})
	if !started {
		t.mu.Lock()
		t.running = false
		t.mu.Unlock()
	}
}

// RunOnce performs a backfill pass synchronously and returns how many
// thumbnails were generated. It is the test seam.
func (t *ThumbRepairer) RunOnce(ctx context.Context) int {
	if t == nil || t.repo == nil || t.thumbDir == "" {
		return 0
	}
	rows, err := t.repo.PendingThumbnails(ctx, ThumbRepairMaxPerRun)
	if err != nil {
		t.logger.Warn("whatsapp: thumbnail backfill list failed", slog.String("error", err.Error()))
		return 0
	}
	generated := 0
	for i := range rows {
		if ctx.Err() != nil {
			break
		}
		md := rows[i]
		data := mediaThumbnail(md.Kind, md.Proto)
		if len(data) == 0 {
			continue
		}
		sha := mediaProtoSHA256(md.Kind, md.Proto)
		if sha == "" {
			sha = sha256HexBytes(md.Proto)
		}
		path, werr := writeThumbFile(t.thumbDir, sha, data)
		if werr != nil {
			t.logger.Debug("whatsapp: thumbnail backfill write failed",
				slog.String("kind", md.Kind),
				slog.String("error", werr.Error()))
			continue
		}
		if serr := t.repo.SetMediaThumbPath(ctx, md.MessageID, path); serr != nil {
			t.logger.Warn("whatsapp: thumbnail backfill persist failed",
				slog.String("error", serr.Error()))
			continue
		}
		generated++
	}
	if generated > 0 {
		t.logger.Info("whatsapp: thumbnail backfill done", slog.Int("generated", generated))
	}
	return generated
}
