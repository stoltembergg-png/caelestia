package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrNotFound is returned when a requested row does not exist.
var ErrNotFound = errors.New("database: not found")

// Default pagination limits used when a caller passes a non-positive limit.
const (
	DefaultListLimit = 100
	MaxListLimit     = 1000
)

// dbtx is the subset of database/sql used by Repo. It is implemented by both
// *sql.DB and *sql.Tx, so the same methods run on the pool or inside a
// transaction opened by WithTx.
type dbtx interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// Repo is the data-access layer over the cae_* tables. It never touches the
// whatsmeow_* tables (those are owned by sqlstore).
//
// All methods take a context so callers can cancel long queries; the underlying
// *sql.DB uses a single writer connection (see Open), which serializes writes.
type Repo struct {
	db dbtx
}

// NewRepo wraps db in a repository. db must be non-nil and already migrated.
func NewRepo(db *sql.DB) *Repo {
	return &Repo{db: db}
}

// WithTx runs fn inside a single transaction, handing it a Repo bound to that
// transaction. Every write fn performs is committed atomically (or rolled back
// on error), which is used by history sync to amortize the per-statement fsync
// cost. The existing methods stay idempotent, so a retried batch is safe.
//
// WithTx must be called on a Repo opened over a *sql.DB; nested calls return an
// error.
func (r *Repo) WithTx(ctx context.Context, fn func(*Repo) error) error {
	db, ok := r.db.(*sql.DB)
	if !ok {
		return errors.New("database: WithTx: nested transaction")
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("database: begin transaction: %w", err)
	}
	defer func() {
		// Rollback is a no-op after a successful Commit.
		_ = tx.Rollback()
	}()
	if err := fn(&Repo{db: tx}); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("database: commit transaction: %w", err)
	}
	return nil
}

// Chat is a row of cae_chats.
type Chat struct {
	JID           string
	Kind          string // "dm" or "group"
	Name          string
	LastMessageID string
	LastMessageTS int64 // Unix milliseconds; 0 means unknown
	LastPreview   string
	UnreadCount   int
	Pinned        bool
	Archived      bool
	MuteUntil     int64
	UpdatedAt     int64
}

// Contact is a row of cae_contacts.
type Contact struct {
	JID          string
	FirstName    string
	FullName     string
	PushName     string
	BusinessName string
	AvatarID     string
	AvatarPath   string
}

// Group is a row of cae_groups.
type Group struct {
	JID              string
	Name             string
	Topic            string
	ParticipantsJSON string
}

// Message is a row of cae_messages.
type Message struct {
	ID         string
	ChatJID    string
	SenderJID  string
	FromMe     bool
	Timestamp  int64 // Unix milliseconds
	Type       string
	Text       string
	QuotedID   string
	ReactionTo string
	Edited     bool
	Deleted    bool
	ServerID   int64
	Status     string
	MediaID    string
}

// Receipt is a row of cae_receipts.
type Receipt struct {
	MessageID string
	UserJID   string
	Type      string
	TS        int64 // Unix milliseconds
}

// Reaction is a row of cae_reactions. It is keyed by (MessageID, SenderJID):
// one current reaction per sender on a message. An empty Emoji removes it.
type Reaction struct {
	MessageID string
	ChatJID   string
	SenderJID string
	Emoji     string
	FromMe    bool
	Timestamp int64 // Unix milliseconds
}

// MessageRef is the minimal information needed to send a read receipt.
type MessageRef struct {
	ID        string
	SenderJID string
}

// normalizeLimit clamps a caller-supplied limit into [1, MaxListLimit].
func normalizeLimit(limit int) int {
	if limit <= 0 {
		return DefaultListLimit
	}
	if limit > MaxListLimit {
		return MaxListLimit
	}
	return limit
}

// UpsertChat inserts a chat or refines an existing one. An empty name never
// overwrites a known name, and a group kind is never downgraded to dm.
func (r *Repo) UpsertChat(ctx context.Context, c Chat) error {
	if c.JID == "" {
		return errors.New("database: upsert chat: empty jid")
	}
	kind := "dm"
	if c.Kind == "group" {
		kind = "group"
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_chats (jid, kind, name, updated_at)
		VALUES (?, ?, ?, unixepoch())
		ON CONFLICT (jid) DO UPDATE SET
			kind = CASE WHEN excluded.kind = 'group' THEN 'group' ELSE cae_chats.kind END,
			name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE cae_chats.name END,
			updated_at = unixepoch()`,
		c.JID, kind, c.Name,
	)
	if err != nil {
		return fmt.Errorf("database: upsert chat %q: %w", c.JID, err)
	}
	return nil
}

// UpdateChatLastMessage stores the most recent message of a chat, but only when
// ts is newer than (or equal to) the stored one. It does not touch unread_count.
func (r *Repo) UpdateChatLastMessage(ctx context.Context, jid, messageID string, ts int64, preview string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE cae_chats SET
			last_message_id = CASE WHEN last_message_ts IS NULL OR ? >= last_message_ts THEN ? ELSE last_message_id END,
			last_preview    = CASE WHEN last_message_ts IS NULL OR ? >= last_message_ts THEN ? ELSE last_preview END,
			last_message_ts = CASE WHEN last_message_ts IS NULL OR ? >= last_message_ts THEN ? ELSE last_message_ts END,
			updated_at      = unixepoch()
		WHERE jid = ?`,
		ts, messageID, ts, preview, ts, ts, jid,
	)
	if err != nil {
		return fmt.Errorf("database: update chat last message %q: %w", jid, err)
	}
	return nil
}

// SetChatLastTimestamp updates only last_message_ts (when newer) without
// clobbering the last_message_id/preview. Used by history sync.
func (r *Repo) SetChatLastTimestamp(ctx context.Context, jid string, ts int64) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE cae_chats SET
			last_message_ts = CASE WHEN last_message_ts IS NULL OR ? >= last_message_ts THEN ? ELSE last_message_ts END,
			updated_at      = unixepoch()
		WHERE jid = ?`,
		ts, ts, jid,
	)
	if err != nil {
		return fmt.Errorf("database: set chat last timestamp %q: %w", jid, err)
	}
	return nil
}

// IncrementUnread adds one to the unread counter of a chat.
func (r *Repo) IncrementUnread(ctx context.Context, jid string) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE cae_chats SET unread_count = unread_count + 1, updated_at = unixepoch() WHERE jid = ?`,
		jid,
	)
	if err != nil {
		return fmt.Errorf("database: increment unread %q: %w", jid, err)
	}
	return nil
}

// SetUnread overwrites the unread counter of a chat (history sync is
// authoritative about the count).
func (r *Repo) SetUnread(ctx context.Context, jid string, count int) error {
	if count < 0 {
		count = 0
	}
	_, err := r.db.ExecContext(ctx,
		`UPDATE cae_chats SET unread_count = ?, updated_at = unixepoch() WHERE jid = ?`,
		count, jid,
	)
	if err != nil {
		return fmt.Errorf("database: set unread %q: %w", jid, err)
	}
	return nil
}

// MarkChatRead zeroes the unread counter of a chat.
func (r *Repo) MarkChatRead(ctx context.Context, jid string) error {
	return r.SetUnread(ctx, jid, 0)
}

// GetChat returns the chat with the given JID, or ErrNotFound.
func (r *Repo) GetChat(ctx context.Context, jid string) (*Chat, error) {
	row := r.db.QueryRowContext(ctx, chatSelect+` WHERE jid = ?`, jid)
	c, err := scanChat(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("database: get chat %q: %w", jid, err)
	}
	return c, nil
}

const chatSelect = `
	SELECT jid, kind, name,
	       COALESCE(last_message_id, ''), COALESCE(last_message_ts, 0),
	       COALESCE(last_preview, ''), unread_count,
	       pinned, archived, COALESCE(mute_until, 0), updated_at
	FROM cae_chats`

// ListChats returns chats ordered by last_message_ts descending (chats without
// messages last), then by jid for a stable order.
func (r *Repo) ListChats(ctx context.Context, limit int) ([]Chat, error) {
	rows, err := r.db.QueryContext(ctx, chatSelect+`
		ORDER BY (last_message_ts IS NULL), last_message_ts DESC, jid
		LIMIT ?`, normalizeLimit(limit))
	if err != nil {
		return nil, fmt.Errorf("database: list chats: %w", err)
	}
	defer rows.Close()

	chats := make([]Chat, 0, 16)
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, fmt.Errorf("database: scan chat: %w", err)
		}
		chats = append(chats, *c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("database: iterate chats: %w", err)
	}
	return chats, nil
}

// rowScanner is implemented by *sql.Row and *sql.Rows.
type rowScanner interface {
	Scan(dest ...any) error
}

func scanChat(s rowScanner) (*Chat, error) {
	var (
		c        Chat
		pinned   int
		archived int
	)
	if err := s.Scan(
		&c.JID, &c.Kind, &c.Name,
		&c.LastMessageID, &c.LastMessageTS,
		&c.LastPreview, &c.UnreadCount,
		&pinned, &archived, &c.MuteUntil, &c.UpdatedAt,
	); err != nil {
		return nil, err
	}
	c.Pinned = pinned != 0
	c.Archived = archived != 0
	return &c, nil
}

// UpsertContact inserts or refines a contact. Empty fields never overwrite
// previously known values.
func (r *Repo) UpsertContact(ctx context.Context, c Contact) error {
	if c.JID == "" {
		return errors.New("database: upsert contact: empty jid")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_contacts
			(jid, first_name, full_name, push_name, business_name, avatar_id, avatar_path, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, unixepoch())
		ON CONFLICT (jid) DO UPDATE SET
			first_name    = CASE WHEN excluded.first_name    <> '' THEN excluded.first_name    ELSE cae_contacts.first_name    END,
			full_name     = CASE WHEN excluded.full_name     <> '' THEN excluded.full_name     ELSE cae_contacts.full_name     END,
			push_name     = CASE WHEN excluded.push_name     <> '' THEN excluded.push_name     ELSE cae_contacts.push_name     END,
			business_name = CASE WHEN excluded.business_name <> '' THEN excluded.business_name ELSE cae_contacts.business_name END,
			avatar_id     = CASE WHEN excluded.avatar_id     <> '' THEN excluded.avatar_id     ELSE cae_contacts.avatar_id     END,
			avatar_path   = CASE WHEN excluded.avatar_path   <> '' THEN excluded.avatar_path   ELSE cae_contacts.avatar_path   END,
			updated_at    = unixepoch()`,
		c.JID, c.FirstName, c.FullName, c.PushName, c.BusinessName, c.AvatarID, c.AvatarPath,
	)
	if err != nil {
		return fmt.Errorf("database: upsert contact %q: %w", c.JID, err)
	}
	return nil
}

// GetContact returns the contact with the given JID, or ErrNotFound.
func (r *Repo) GetContact(ctx context.Context, jid string) (*Contact, error) {
	var c Contact
	err := r.db.QueryRowContext(ctx, `
		SELECT jid, COALESCE(first_name, ''), COALESCE(full_name, ''),
		       COALESCE(push_name, ''), COALESCE(business_name, ''),
		       COALESCE(avatar_id, ''), COALESCE(avatar_path, '')
		FROM cae_contacts WHERE jid = ?`, jid,
	).Scan(&c.JID, &c.FirstName, &c.FullName, &c.PushName, &c.BusinessName, &c.AvatarID, &c.AvatarPath)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("database: get contact %q: %w", jid, err)
	}
	return &c, nil
}

// SearchContacts returns contacts whose JID or names contain query (case
// insensitive LIKE), ordered by name. An empty query returns the first page.
// The user query is escaped so '%' and '_' are matched literally.
func (r *Repo) SearchContacts(ctx context.Context, query string, limit int) ([]Contact, error) {
	trimmed := strings.TrimSpace(query)
	like := "%" + escapeLike(trimmed) + "%"
	rows, err := r.db.QueryContext(ctx, `
		SELECT jid, COALESCE(first_name, ''), COALESCE(full_name, ''),
		       COALESCE(push_name, ''), COALESCE(business_name, ''),
		       COALESCE(avatar_id, ''), COALESCE(avatar_path, '')
		FROM cae_contacts
		WHERE (? = '%%' OR jid LIKE ? ESCAPE '\' OR full_name LIKE ? ESCAPE '\'
		       OR push_name LIKE ? ESCAPE '\' OR first_name LIKE ? ESCAPE '\')
		ORDER BY (full_name = ''), full_name, push_name, jid
		LIMIT ?`,
		like, like, like, like, like, normalizeLimit(limit),
	)
	if err != nil {
		return nil, fmt.Errorf("database: search contacts: %w", err)
	}
	defer rows.Close()

	contacts := make([]Contact, 0, 16)
	for rows.Next() {
		var c Contact
		if err := rows.Scan(&c.JID, &c.FirstName, &c.FullName, &c.PushName, &c.BusinessName, &c.AvatarID, &c.AvatarPath); err != nil {
			return nil, fmt.Errorf("database: scan contact: %w", err)
		}
		contacts = append(contacts, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("database: iterate contacts: %w", err)
	}
	return contacts, nil
}

// escapeLike escapes the LIKE metacharacters ('%', '_' and the escape
// character itself) so a user query is matched literally. Callers must pair it
// with ESCAPE '\' in the SQL.
func escapeLike(s string) string {
	if !strings.ContainsAny(s, `\%_`) {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + 4)
	for _, r := range s {
		if r == '\\' || r == '%' || r == '_' {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// UpsertGroup inserts or refines a group. Empty fields never overwrite known
// values.
func (r *Repo) UpsertGroup(ctx context.Context, g Group) error {
	if g.JID == "" {
		return errors.New("database: upsert group: empty jid")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_groups (jid, name, topic, participants_json, updated_at)
		VALUES (?, ?, ?, ?, unixepoch())
		ON CONFLICT (jid) DO UPDATE SET
			name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE cae_groups.name END,
			topic = CASE WHEN excluded.topic <> '' THEN excluded.topic ELSE cae_groups.topic END,
			participants_json = CASE WHEN excluded.participants_json <> '' THEN excluded.participants_json ELSE cae_groups.participants_json END,
			updated_at = unixepoch()`,
		g.JID, g.Name, g.Topic, g.ParticipantsJSON,
	)
	if err != nil {
		return fmt.Errorf("database: upsert group %q: %w", g.JID, err)
	}
	return nil
}

// GetGroup returns the group with the given JID, or ErrNotFound.
func (r *Repo) GetGroup(ctx context.Context, jid string) (*Group, error) {
	var g Group
	err := r.db.QueryRowContext(ctx, `
		SELECT jid, COALESCE(name, ''), COALESCE(topic, ''), COALESCE(participants_json, '')
		FROM cae_groups WHERE jid = ?`, jid,
	).Scan(&g.JID, &g.Name, &g.Topic, &g.ParticipantsJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("database: get group %q: %w", jid, err)
	}
	return &g, nil
}

// InsertMessage inserts a message idempotently (PK = id). It returns true when
// a new row was created and false when the message already existed.
func (r *Repo) InsertMessage(ctx context.Context, m Message) (bool, error) {
	if m.ID == "" {
		return false, errors.New("database: insert message: empty id")
	}
	fromMe := 0
	if m.FromMe {
		fromMe = 1
	}
	edited := 0
	if m.Edited {
		edited = 1
	}
	deleted := 0
	if m.Deleted {
		deleted = 1
	}
	res, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_messages
			(id, chat_jid, sender_jid, from_me, timestamp, type, text, quoted_id,
			 reaction_to, edited, deleted, server_id, status, media_id)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, 0), NULLIF(?, ''), NULLIF(?, ''))
		ON CONFLICT (id) DO NOTHING`,
		m.ID, m.ChatJID, nullString(m.SenderJID), fromMe, m.Timestamp, m.Type, nullString(m.Text),
		nullString(m.QuotedID), nullString(m.ReactionTo), edited, deleted, m.ServerID, m.Status, m.MediaID,
	)
	if err != nil {
		return false, fmt.Errorf("database: insert message %q: %w", m.ID, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("database: insert message %q: %w", m.ID, err)
	}
	return n > 0, nil
}

// GetMessage returns one message by ID, or ErrNotFound.
func (r *Repo) GetMessage(ctx context.Context, id string) (*Message, error) {
	row := r.db.QueryRowContext(ctx, messageSelect+` WHERE id = ?`, id)
	m, err := scanMessage(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("database: get message %q: %w", id, err)
	}
	return m, nil
}

const messageSelect = `
	SELECT id, chat_jid, COALESCE(sender_jid, ''), from_me, timestamp, type,
	       COALESCE(text, ''), COALESCE(quoted_id, ''), COALESCE(reaction_to, ''),
	       edited, deleted, COALESCE(server_id, 0), COALESCE(status, ''), COALESCE(media_id, '')
	FROM cae_messages`

func scanMessage(s rowScanner) (*Message, error) {
	var (
		m       Message
		fromMe  int
		edited  int
		deleted int
	)
	if err := s.Scan(
		&m.ID, &m.ChatJID, &m.SenderJID, &fromMe, &m.Timestamp, &m.Type,
		&m.Text, &m.QuotedID, &m.ReactionTo, &edited, &deleted, &m.ServerID, &m.Status, &m.MediaID,
	); err != nil {
		return nil, err
	}
	m.FromMe = fromMe != 0
	m.Edited = edited != 0
	m.Deleted = deleted != 0
	return &m, nil
}

// ListMessages returns the most recent messages of a chat, newest first. When
// beforeTS > 0 only messages strictly older than beforeTS are returned.
func (r *Repo) ListMessages(ctx context.Context, chatJID string, limit int, beforeTS int64) ([]Message, error) {
	rows, err := r.db.QueryContext(ctx, messageSelect+`
		WHERE chat_jid = ? AND (? <= 0 OR timestamp < ?)
		ORDER BY timestamp DESC, id DESC
		LIMIT ?`,
		chatJID, beforeTS, beforeTS, normalizeLimit(limit),
	)
	if err != nil {
		return nil, fmt.Errorf("database: list messages %q: %w", chatJID, err)
	}
	defer rows.Close()

	msgs := make([]Message, 0, 16)
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, fmt.Errorf("database: scan message: %w", err)
		}
		msgs = append(msgs, *m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("database: iterate messages: %w", err)
	}
	return msgs, nil
}

// PendingIncomingMessages returns the incoming messages of a chat that have not
// been marked read yet, oldest first. Used by message.read.
func (r *Repo) PendingIncomingMessages(ctx context.Context, chatJID string) ([]MessageRef, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, COALESCE(sender_jid, '') FROM cae_messages
		WHERE chat_jid = ? AND from_me = 0 AND COALESCE(status, '') <> 'read'
		ORDER BY timestamp ASC, id ASC`, chatJID)
	if err != nil {
		return nil, fmt.Errorf("database: pending messages %q: %w", chatJID, err)
	}
	defer rows.Close()

	refs := make([]MessageRef, 0, 16)
	for rows.Next() {
		var ref MessageRef
		if err := rows.Scan(&ref.ID, &ref.SenderJID); err != nil {
			return nil, fmt.Errorf("database: scan pending message: %w", err)
		}
		refs = append(refs, ref)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("database: iterate pending messages: %w", err)
	}
	return refs, nil
}

// SetMessagesStatus sets the status of the given messages. For "delivered" an
// already "read" status is preserved (no downgrade).
func (r *Repo) SetMessagesStatus(ctx context.Context, ids []string, status string) error {
	if len(ids) == 0 {
		return nil
	}
	args := make([]any, 0, len(ids)+1)
	args = append(args, status)
	for _, id := range ids {
		args = append(args, id)
	}
	query := `UPDATE cae_messages SET status = ? WHERE id IN (` + placeholders(len(ids)) + `)`
	if status == "delivered" {
		query += ` AND COALESCE(status, '') <> 'read'`
	}
	if _, err := r.db.ExecContext(ctx, query, args...); err != nil {
		return fmt.Errorf("database: set messages status: %w", err)
	}
	return nil
}

// SetMessageEdited marks a message as edited and optionally replaces its text.
func (r *Repo) SetMessageEdited(ctx context.Context, id, text string) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE cae_messages SET edited = 1, deleted = 0, text = CASE WHEN ? <> '' THEN ? ELSE text END WHERE id = ?`,
		text, text, id,
	)
	if err != nil {
		return fmt.Errorf("database: edit message %q: %w", id, err)
	}
	return nil
}

// SetMessageDeleted marks a message as deleted and clears its text.
func (r *Repo) SetMessageDeleted(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx,
		`UPDATE cae_messages SET deleted = 1, text = NULL WHERE id = ?`, id,
	)
	if err != nil {
		return fmt.Errorf("database: delete message %q: %w", id, err)
	}
	return nil
}

// InsertReceipt inserts a receipt idempotently. It is a no-op when the
// referenced message does not exist (receipts may race ahead of history sync).
func (r *Repo) InsertReceipt(ctx context.Context, rec Receipt) error {
	if rec.MessageID == "" || rec.UserJID == "" || rec.Type == "" {
		return nil
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_receipts (message_id, user_jid, type, ts)
		SELECT ?, ?, ?, ?
		WHERE EXISTS (SELECT 1 FROM cae_messages WHERE id = ?)
		ON CONFLICT (message_id, user_jid, type) DO UPDATE SET ts = excluded.ts`,
		rec.MessageID, rec.UserJID, rec.Type, rec.TS, rec.MessageID,
	)
	if err != nil {
		return fmt.Errorf("database: insert receipt: %w", err)
	}
	return nil
}

// UpsertReaction inserts or replaces the current reaction of a sender on a
// message. An empty emoji means the reaction was removed and deletes the row.
// It is a no-op when the target message does not exist (reactions may race
// ahead of history sync), mirroring InsertReceipt.
func (r *Repo) UpsertReaction(ctx context.Context, x Reaction) error {
	if x.MessageID == "" || x.SenderJID == "" {
		return nil
	}
	if strings.TrimSpace(x.Emoji) == "" {
		return r.DeleteReaction(ctx, x.MessageID, x.SenderJID)
	}
	fromMe := 0
	if x.FromMe {
		fromMe = 1
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_reactions (message_id, sender_jid, chat_jid, emoji, from_me, timestamp)
		SELECT ?, ?, ?, ?, ?, ?
		WHERE EXISTS (SELECT 1 FROM cae_messages WHERE id = ?)
		ON CONFLICT (message_id, sender_jid) DO UPDATE SET
			chat_jid  = excluded.chat_jid,
			emoji     = excluded.emoji,
			from_me   = excluded.from_me,
			timestamp = excluded.timestamp`,
		x.MessageID, x.SenderJID, x.ChatJID, x.Emoji, fromMe, x.Timestamp, x.MessageID,
	)
	if err != nil {
		return fmt.Errorf("database: upsert reaction on %q: %w", x.MessageID, err)
	}
	return nil
}

// DeleteReaction removes a sender's reaction from a message.
func (r *Repo) DeleteReaction(ctx context.Context, messageID, senderJID string) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM cae_reactions WHERE message_id = ? AND sender_jid = ?`,
		messageID, senderJID,
	)
	if err != nil {
		return fmt.Errorf("database: delete reaction on %q: %w", messageID, err)
	}
	return nil
}

// ListReactions returns the current reactions of a message, ordered by sender.
func (r *Repo) ListReactions(ctx context.Context, messageID string) ([]Reaction, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT message_id, COALESCE(chat_jid, ''), sender_jid, emoji, from_me, timestamp
		FROM cae_reactions WHERE message_id = ? ORDER BY sender_jid`, messageID)
	if err != nil {
		return nil, fmt.Errorf("database: list reactions %q: %w", messageID, err)
	}
	defer rows.Close()

	reactions := make([]Reaction, 0, 4)
	for rows.Next() {
		var (
			x      Reaction
			fromMe int
		)
		if err := rows.Scan(&x.MessageID, &x.ChatJID, &x.SenderJID, &x.Emoji, &fromMe, &x.Timestamp); err != nil {
			return nil, fmt.Errorf("database: scan reaction: %w", err)
		}
		x.FromMe = fromMe != 0
		reactions = append(reactions, x)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("database: iterate reactions: %w", err)
	}
	return reactions, nil
}

// UnreadTotal returns the sum of unread_count across all chats.
func (r *Repo) UnreadTotal(ctx context.Context) (int, error) {
	var total int
	if err := r.db.QueryRowContext(ctx,
		`SELECT COALESCE(SUM(unread_count), 0) FROM cae_chats`).Scan(&total); err != nil {
		return 0, fmt.Errorf("database: unread total: %w", err)
	}
	return total, nil
}

// GetSyncState returns the value stored under key, or ErrNotFound.
func (r *Repo) GetSyncState(ctx context.Context, key string) (string, error) {
	var value string
	err := r.db.QueryRowContext(ctx,
		`SELECT COALESCE(value, '') FROM cae_sync_state WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("database: get sync state %q: %w", key, err)
	}
	return value, nil
}

// SetSyncState inserts or updates a key/value sync-state pair.
func (r *Repo) SetSyncState(ctx context.Context, key, value string) error {
	if key == "" {
		return errors.New("database: set sync state: empty key")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO cae_sync_state (key, value) VALUES (?, ?)
		ON CONFLICT (key) DO UPDATE SET value = excluded.value`,
		key, value,
	)
	if err != nil {
		return fmt.Errorf("database: set sync state %q: %w", key, err)
	}
	return nil
}

// placeholders returns "?, ?, ..." with n placeholders.
func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimSuffix(strings.Repeat("?,", n), ",")
}

// nullString maps "" to NULL so optional text columns stay null.
func nullString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
