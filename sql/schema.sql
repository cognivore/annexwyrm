-- annexwyrm schema, SQLite dialect.
--
-- Conventions:
--   * Every row has a stable string `id`; for local objects this is the
--     full HTTPS URL (matches AP `id`). For remote rows it is the URL we
--     fetched it from.
--   * Timestamps are ISO 8601 UTC strings (`2026-06-04T12:34:56Z`).
--     Sortable lexicographically; SQLite has no native datetime type.
--   * The blob storage (rclone, git-annex) is *not* the database; we
--     record where each file lives, never its bytes.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- Local + cached-remote actors. Multitenant: there are MANY local actors
-- (rows with local=1), one per tenant, each with its own keypair and login.
-- The bootstrap actor (created at `init` from the env username) is the admin
-- (is_admin=1) and the only one who can mint invites.
CREATE TABLE IF NOT EXISTS actor (
    id              TEXT PRIMARY KEY,           -- https://domain/users/name
    local           INTEGER NOT NULL,           -- 1 = a local tenant, 0 = a cached remote
    username        TEXT NOT NULL,              -- 'alice'
    domain          TEXT NOT NULL,              -- 'annexwyrm.example.com'
    name            TEXT,                       -- display name, may be NULL
    summary         TEXT,                       -- bio HTML, may be NULL
    icon_url        TEXT,                       -- avatar, may be NULL
    inbox           TEXT NOT NULL,
    outbox          TEXT NOT NULL,
    followers       TEXT NOT NULL,
    following       TEXT NOT NULL,
    shared_inbox    TEXT,                       -- nullable
    public_key_pem  TEXT NOT NULL,              -- PEM-encoded RSA pubkey
    private_key_pem TEXT,                       -- only for local actors
    manually_approves INTEGER NOT NULL DEFAULT 0,
    discoverable    INTEGER NOT NULL DEFAULT 1,
    is_admin        INTEGER NOT NULL DEFAULT 0, -- 1 = may mint invites (the bootstrap tenant)
    created_at      TEXT NOT NULL,
    fetched_at      TEXT                        -- last refresh for remotes
);
-- Usernames are unique among local actors on a domain (one tenant per name).
CREATE UNIQUE INDEX IF NOT EXISTS actor_local_user
    ON actor(domain, username) WHERE local = 1;

-- Migration for DBs created before multitenancy: the C bridge
-- (csrc/db_bridge.c, aw_migrate_actor) probes PRAGMA table_info(actor) and
-- runs this idempotently on every open/init.
--   ALTER TABLE actor ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0;

-- A login for a local actor. Password is argon2id.
CREATE TABLE IF NOT EXISTS local_login (
    actor_id        TEXT PRIMARY KEY REFERENCES actor(id) ON DELETE CASCADE,
    password_hash   TEXT NOT NULL,
    created_at      TEXT NOT NULL
);

-- Browser sessions. Token is a 256-bit random hex string set as cookie.
CREATE TABLE IF NOT EXISTS session (
    token           TEXT PRIMARY KEY,
    actor_id        TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    created_at      TEXT NOT NULL,
    expires_at      TEXT NOT NULL
);

-- The archive. Each row is one piece of content. Bytes live in `remote`
-- rows (one item, many mirrors); this row is the metadata.
--
-- Single-tenant public review site: there is NO per-item privacy. Every
-- item is always public and federates immediately. The only gate is the
-- file blob: file_published = 0 (archived, encrypted remote only, no
-- download link, empty AP url[]) or 1 (also on the public remote, with a
-- minted download URL that goes in url[]). The old `privacy` column is
-- DROPPED from this fresh schema; on DBs carried over from the old schema
-- it is kept-dead (never read/written) — see the migration note below.
CREATE TABLE IF NOT EXISTS item (
    id              TEXT PRIMARY KEY,           -- https://domain/items/<hex>
    owner_id        TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    object_type     TEXT NOT NULL,              -- 'Note'|'Article'|'Document'|'Audio'|'Video'|'Image'
    name            TEXT,                       -- title; required for Article
    summary         TEXT,                       -- content-warning / abstract
    content         TEXT,                       -- HTML; NULL for pure-file items
    media_type      TEXT,                       -- 'application/pdf', 'audio/mpeg', …
    byte_size       INTEGER,                    -- bytes; NULL if unknown
    sha256          TEXT,                       -- hex
    rating          INTEGER,                    -- -3..3, NULL = unrated (the 7-point Likert scale)
    in_reply_to     TEXT,                       -- AP `inReplyTo`; reviews point at the reviewed item
    file_published  INTEGER NOT NULL DEFAULT 0, -- 0 = archived (encrypted only); 1 = published (public + url[])
    file_public_url TEXT,                       -- uc?export=download form; NULL until published
    file_view_url   TEXT,                       -- open?id viewer mirror; NULL until published
    published_at    TEXT NOT NULL,              -- when first published
    updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS item_owner_published ON item(owner_id, published_at DESC);
CREATE INDEX IF NOT EXISTS item_in_reply_to ON item(in_reply_to);

-- Tags / hashtags for an item. Normalised: lowercase, no leading '#'. One
-- row per (item, tag); they federate as AP `Hashtag` entries in the object's
-- `tag` array and back the /tags/<tag> listing and search. Created with
-- IF NOT EXISTS so `init` adds it to carried-over DBs with no migration code.
CREATE TABLE IF NOT EXISTS item_tag (
    item_id         TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    tag             TEXT NOT NULL,              -- lowercase, no '#'
    PRIMARY KEY (item_id, tag)
);
CREATE INDEX IF NOT EXISTS item_tag_tag ON item_tag(tag);

-- Migration for DBs created under the old (privacy) schema. The C bridge
-- (csrc/db_bridge.c, kk_aw_db_init_schema) probes PRAGMA table_info(item)
-- and runs these idempotently — DROP COLUMN-free (portable across the
-- darwin/Ubuntu SQLite versions) and re-runnable as a no-op. The dead
-- `privacy` column is left in place; nothing reads or writes it.
--   ALTER TABLE item ADD COLUMN file_published INTEGER NOT NULL DEFAULT 0;
--   ALTER TABLE item ADD COLUMN file_public_url TEXT;
--   ALTER TABLE item ADD COLUMN file_view_url TEXT;

-- Remotes / mirrors for an item. Order matters: the first row with
-- `published = 1` is what we put first in the `url` array.
CREATE TABLE IF NOT EXISTS item_remote (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id         TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL,              -- 'url'|'rclone'|'git-annex'|'ipfs'
    target          TEXT NOT NULL,              -- the URL, rclone path, magnet, …
    media_type      TEXT,                       -- override for this mirror, else inherit
    label           TEXT,                       -- 'rsync.net primary' etc.
    published       INTEGER NOT NULL DEFAULT 0, -- 1 ⇒ appears in AP url[]
    sort_order      INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS item_remote_item ON item_remote(item_id, sort_order);

-- Activities: one row per Create / Like / Follow / Announce / … that
-- either we sent or we received. Used for the outbox, the inbox, and
-- the federation log.
CREATE TABLE IF NOT EXISTS activity (
    id              TEXT PRIMARY KEY,           -- https://domain/activities/<hex>
    actor_id        TEXT NOT NULL,              -- may not exist in `actor` if remote
    type            TEXT NOT NULL,              -- 'Create'|'Follow'|…
    object_id       TEXT,                       -- AP `object` if it's a string
    target_id       TEXT,                       -- AP `target` (Add/Remove)
    inbox_remote    INTEGER NOT NULL,           -- 1 ⇒ arrived from outside
    raw             TEXT NOT NULL,              -- the original JSON-LD blob
    addressed_to    TEXT NOT NULL,              -- JSON array, normalised
    received_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS activity_actor ON activity(actor_id, received_at DESC);
CREATE INDEX IF NOT EXISTS activity_object ON activity(object_id);

-- Follow relationships.
CREATE TABLE IF NOT EXISTS follow (
    id              TEXT PRIMARY KEY,           -- the Follow activity id
    follower_id     TEXT NOT NULL,              -- who is following
    target_id       TEXT NOT NULL,              -- whom they follow
    state           TEXT NOT NULL,              -- 'pending'|'accepted'|'rejected'
    created_at      TEXT NOT NULL,
    accepted_at     TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS follow_pair ON follow(follower_id, target_id);
CREATE INDEX IF NOT EXISTS follow_target_state ON follow(target_id, state);

-- Likes / favourites.
CREATE TABLE IF NOT EXISTS like_ (
    id              TEXT PRIMARY KEY,           -- the Like activity id
    actor_id        TEXT NOT NULL,
    object_id       TEXT NOT NULL,
    created_at      TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS like_pair ON like_(actor_id, object_id);
CREATE INDEX IF NOT EXISTS like_object ON like_(object_id);

-- Announce / boost.
CREATE TABLE IF NOT EXISTS announce (
    id              TEXT PRIMARY KEY,
    actor_id        TEXT NOT NULL,
    object_id       TEXT NOT NULL,
    created_at      TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS announce_pair ON announce(actor_id, object_id);
CREATE INDEX IF NOT EXISTS announce_object ON announce(object_id);

-- Delivery queue. Outbound POSTs that haven't gone through yet.
-- A worker thread (or a periodic cron) drains this.
CREATE TABLE IF NOT EXISTS delivery (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    activity_id     TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
    sender_id       TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    inbox_url       TEXT NOT NULL,              -- exact URL we POST to
    next_attempt    TEXT NOT NULL,              -- ISO 8601; ready when ≤ now()
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    state           TEXT NOT NULL DEFAULT 'pending' -- 'pending'|'success'|'failed'
);
CREATE INDEX IF NOT EXISTS delivery_ready ON delivery(state, next_attempt);

-- Singleton key=value settings (domain, instance name, registration policy).
CREATE TABLE IF NOT EXISTS setting (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL
);

-- Per-tenant blob backend. Each local actor brings its OWN rclone config and
-- remote targets: its uploads land on its own cloud, and when another tenant
-- views one of its files the daemon decrypts/streams through THIS config.
-- `rclone_conf` is the verbatim rclone.conf text (carries cloud secrets);
-- it is materialised to a 0600 file under <data-dir>/storage/ on demand and
-- passed to rclone via `--config`. An empty `rclone_conf` means "use the
-- daemon's ambient ~/.config/rclone" — the bootstrap/admin tenant, whose
-- remotes come from the ANNEXWYRM_*_REMOTE env vars (seeded at startup).
CREATE TABLE IF NOT EXISTS tenant_storage (
    actor_id        TEXT PRIMARY KEY REFERENCES actor(id) ON DELETE CASCADE,
    rclone_conf     TEXT NOT NULL DEFAULT '',   -- verbatim rclone.conf; '' = ambient
    archive_remote  TEXT NOT NULL,              -- e.g. 'archive-crypt:annexwyrm'
    public_remote   TEXT NOT NULL,              -- e.g. 'public:annexwyrm-public'
    public_url_base TEXT NOT NULL DEFAULT '',   -- CDN/test seam; '' = `rclone link`
    updated_at      TEXT NOT NULL
);

-- Invite-only registration. An admin mints a single-use token; /register
-- consumes it to create a new local actor. `used_by` NULL ⇒ still open;
-- a token is valid while open AND expires_at > now().
CREATE TABLE IF NOT EXISTS invite (
    token           TEXT PRIMARY KEY,           -- 256-bit random hex
    created_by      TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    note            TEXT NOT NULL DEFAULT '',   -- admin's memo
    created_at      TEXT NOT NULL,
    expires_at      TEXT NOT NULL,              -- ISO 8601; open while > now()
    used_by         TEXT,                       -- actor id once consumed; NULL while open
    used_at         TEXT
);
CREATE INDEX IF NOT EXISTS invite_open ON invite(used_by, expires_at);
