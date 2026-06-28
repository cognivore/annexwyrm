// annexwyrm/effects/store — blob storage.
//
// One effect, multiple remotes. The handler dispatches by inspecting the
// `remote` argument (e.g. an rclone remote name like "rsyncnet" or a
// git-annex special-remote name like "rsync-net").
//
// The blob bytes are passed as a Koka string. For sizes that fit in
// memory this is fine; the genuine streaming path lives in the C bridge
// where we read/write through a file descriptor.

module effects/store

// Identifies a remote backend instance. Empty string means "the default
// local-disk staging area".
pub alias remote-handle = string

// A blob location: (remote, key-within-remote) plus the per-tenant backend
// context. `remote` is the FULL rclone remote+prefix as configured (e.g.
// "gdrive-crypt:annexwyrm", or a plain absolute path like "/tmp/archive"
// which rclone treats as the local backend) — it already carries its own ":"
// scheme separator if any. `key` is the per-blob path segment (the item slug).
// The on-disk / on-remote location is therefore `<remote>/<key>`.
//
// `conf` is the path to the OWNING tenant's materialised rclone.conf, passed
// to rclone as `--config <conf>`; "" means "use the daemon's ambient config"
// (the bootstrap/admin tenant). `url-base` is that tenant's public-URL seam
// for blob-public-url; "" means "ask `rclone link`". Both are all-string
// fields so the struct stays koka#654-safe (no raw/ref mix).
pub value struct blob-loc
  remote   : remote-handle
  key      : string
  conf     : string
  url-base : string

// Ambient location: no per-tenant config (uses the daemon's ~/.config/rclone)
// and no URL seam. The shape every call site used before multitenancy.
pub fun blob-loc/ambient( remote : remote-handle, key : string ) : blob-loc
  Blob-loc(remote, key, "", "")

// The rclone path for this blob. We join with "/" (NOT ":") because the
// remote already includes its scheme: "gdrive:bucket" + "/" + "slug" =
// "gdrive:bucket/slug"; "/tmp/archive" + "/" + "slug" = "/tmp/archive/slug".
pub fun blob-loc/show( b : blob-loc ) : string
  if b.remote == "" then b.key else b.remote ++ "/" ++ b.key

pub effect store
  // Upload bytes to `loc`. Overwrites if it already exists.
  fun blob-put( loc : blob-loc, bytes : string ) : ()

  // Download bytes from `loc`. Nothing if absent.
  fun blob-get( loc : blob-loc ) : maybe<string>

  // Remove the blob. No-op if absent.
  fun blob-del( loc : blob-loc ) : ()

  // True iff the blob is present at `loc`.
  fun blob-has( loc : blob-loc ) : bool

  // Size of the blob in bytes, Nothing if absent.
  fun blob-size( loc : blob-loc ) : maybe<int>

  // Return a publicly-reachable HTTPS URL for `loc`, when the remote
  // supports it. For example, an rclone remote pointing at S3 with a
  // public bucket can hand out an https:// URL. Returns Nothing for
  // remotes that can't (private rclone, git-annex).
  fun blob-public-url( loc : blob-loc ) : maybe<string>

  // Materialise tenant `owner`'s rclone config to a private (0600) file and
  // return the path to pass as `rclone --config`. `conf` empty ⇒ returns ""
  // (the daemon's ambient config is used). The secrets in `conf` reach the
  // filesystem only — never argv or the process environment. Idempotent and
  // safe under concurrent calls (atomic replace); the returned path is then
  // carried in each blob-loc's `conf` field for that tenant's operations.
  fun materialize-conf( owner : string, conf : string ) : string

  // Verify the backend at `loc` actually works for storing media: a real
  // round-trip (write a tiny probe object, read it back byte-for-byte, delete
  // it) through this tenant's config. Returns "" on success, or a short
  // human-readable reason (rclone's stderr) on failure — so a tenant learns
  // their secrets are set AND functional before they trust an upload to them.
  // `loc.key` should be a dedicated probe key (e.g. ".annexwyrm-selftest").
  fun storage-self-test( loc : blob-loc ) : string
