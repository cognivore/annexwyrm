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

// A blob location: (remote, key-within-remote). The key is opaque to the
// effect; rclone stores it as a path, git-annex hashes it, IPFS uses
// the CID. Algorithms never construct these directly; they obtain them
// from the AnnexItem record.
pub value struct blob-loc
  remote : remote-handle
  key    : string

pub fun blob-loc/show( b : blob-loc ) : string
  if b.remote == "" then b.key else b.remote ++ ":" ++ b.key

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
