// annexwyrm/annex/storage — per-tenant blob backend resolution.
//
// Multitenancy's storage half. Each local actor (tenant) brings its own
// rclone config + remote targets in the `tenant_storage` table; this module
// loads them, materialises the config to a private file, and hands back a
// `tenant-store` whose `archive-loc`/`public-loc` produce blob-locs already
// carrying that tenant's `--config` path. Every blob operation in the
// handlers goes through one of these, so a tenant's bytes always travel on
// THAT tenant's cloud — and a cross-tenant read decrypts through the OWNER's
// config, never the viewer's.
//
// `tenant-store` and `storage-fields` are all-string value structs (no
// raw/ref mix), so they are koka#654-safe to thread through effectful bodies.

module annex/storage

import core/types
import effects/db
import effects/time
import effects/store

// Operational storage context for one tenant — everything a blob op needs.
// `conf-path` is the materialised rclone.conf path ("" = ambient). `pubrem`
// is the public-download remote target (NOT named `public` — that is a Koka
// keyword).
pub value struct tenant-store
  archive   : string
  pubrem    : string
  url-base  : string
  conf-path : string

// The editable storage settings as a tenant types them — the shape the
// settings form reads and writes. Distinct from `tenant-store`: this carries
// the verbatim rclone.conf text, never a materialised path.
pub value struct storage-fields
  rclone-conf : string
  archive     : string
  pubrem      : string
  url-base    : string

// Resolve `owner`'s operational store: read the row, and if it names an
// archive remote, materialise its rclone.conf to a private file. Nothing when
// the tenant has not configured storage yet (uploads are then refused with a
// clear message; a read of an unconfigured tenant's blob simply 404s).
//
// CRITICAL ISOLATION: there is NO ambient fallback for anyone — admin or not.
// Every tenant (the owner included) must bring their OWN rclone config, so
// their bytes only ever touch THEIR cloud. A blank config (or no archive
// remote) means "not configured yet" → Nothing → uploads are refused. This
// server never stores anyone's files on its own backend or credentials.
pub fun load-tenant-store( owner : url ) : <db,store|e> maybe<tenant-store>
  val rows = query(
    "SELECT rclone_conf, archive_remote, public_remote, public_url_base " ++
    "FROM tenant_storage WHERE actor_id = ?",
    [txt(owner)]
  )
  match rows
    Nil -> Nothing
    Cons(r, _) ->
      val conf    = text(r.col(0))
      val archive = text(r.col(1))
      val pubrem  = text(r.col(2))
      val urlbase = text(r.col(3))
      if archive == "" || conf == "" then Nothing
      else Just(Tenant-store(archive, pubrem, urlbase, materialize-conf(owner, conf)))

// The blob-loc for `key` in this tenant's encrypted archive remote.
pub fun tenant-store/archive-loc( ts : tenant-store, key : string ) : blob-loc
  Blob-loc(ts.archive, key, ts.conf-path, ts.url-base)

// The blob-loc for `key` in this tenant's public download remote.
pub fun tenant-store/pubrem-loc( ts : tenant-store, key : string ) : blob-loc
  Blob-loc(ts.pubrem, key, ts.conf-path, ts.url-base)

// A dedicated probe key the self-test writes/reads/deletes — a dotfile so it
// never collides with a real item slug (those are 12-byte hex).
val self-test-key : string = ".annexwyrm-selftest"

// Self-test this tenant's ARCHIVE backend (the one every upload must reach):
// "" = set and working, else a short failure reason.
pub fun tenant-store/self-test-archive( ts : tenant-store ) : <store|e> string
  storage-self-test(ts.archive-loc(self-test-key))

// Self-test this tenant's PUBLIC backend (used when publishing a file).
pub fun tenant-store/self-test-pubrem( ts : tenant-store ) : <store|e> string
  storage-self-test(ts.pubrem-loc(self-test-key))

// Read a tenant's raw storage fields for the settings form. Returns empty
// fields (not Nothing) when unset, so the form renders blank for a new tenant.
pub fun load-storage-fields( owner : url ) : db storage-fields
  val rows = query(
    "SELECT rclone_conf, archive_remote, public_remote, public_url_base " ++
    "FROM tenant_storage WHERE actor_id = ?",
    [txt(owner)]
  )
  match rows
    Nil -> Storage-fields("", "", "", "")
    Cons(r, _) ->
      Storage-fields(text(r.col(0)), text(r.col(1)), text(r.col(2)), text(r.col(3)))

// Upsert a tenant's storage config (the settings POST lands here). `pubrem` is
// the public-download remote target. A changed config materialises to a new
// content-addressed file on the next blob op, so no cache to invalidate here.
pub fun save-tenant-store(
    owner : url, conf : string, archive : string, pubrem : string, urlbase : string
  ) : <db,time|e> ()
  val now = now-iso()
  val _ = exec(
    "INSERT OR REPLACE INTO tenant_storage " ++
    "(actor_id, rclone_conf, archive_remote, public_remote, public_url_base, updated_at) " ++
    "VALUES (?,?,?,?,?,?)",
    [txt(owner), txt(conf), txt(archive), txt(pubrem), txt(urlbase), txt(now)]
  )
  ()

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }
