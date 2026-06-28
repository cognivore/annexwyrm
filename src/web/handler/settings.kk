// annexwyrm/web/handler/settings — GET /settings, POST /settings (width),
// POST /settings/storage (per-tenant rclone backend). Gated to any logged-in
// tenant; each edits ITS OWN storage config and the site-wide width pref.
//
// The page width is a single site-wide value in the `setting` table (cosmetic;
// shared). The storage section is per-tenant: it reads/writes the session
// actor's `tenant_storage` row — the rclone.conf (cloud secrets) plus the
// archive/public remote targets. The GET carries `Cache-Control: no-store`
// because it echoes those secrets back into the textarea.

module web/handler/settings

import core/types    // url
import core/url
import effects/db
import effects/time
import effects/config
import effects/store  // storage self-test
import annex/storage
import web/prefs
import web/session   // is-tenant-session, session-actor, current-session, is-admin-session
import web/server
import web/html/settings

pub fun handle-settings-form( req : request ) : <db,config,div|e> response
  val owner = session-actor(req)
  if owner == "" then forbidden("login required")
  else
    val w = get-page-width()
    val saved = saved-param(req.query)
    val sf = load-storage-fields(owner)
    val admin = match current-session(req)
      Just(s) -> s.is-admin
      Nothing -> False
    // no-store: the rendered form echoes the tenant's rclone secrets.
    ok-html(render-settings-form(w, saved, sf.rclone-conf, sf.archive,
                                 sf.pubrem, sf.url-base, admin, w))
      .with-header("Cache-Control", "no-store")

pub fun handle-settings-post( req : request ) : <db,config,div|e> response
  if !is-tenant-session(req) then forbidden("login required")
  else
    val w = query-parse(req.body).filter(fn(p) p.fst == "width").head
      .map(fn(p) p.snd).default("")
    if !valid-width(w) then bad-request("invalid width mode")
    else
      set-page-width(w)
      see-other("/settings?saved=width")

// POST /settings/storage — save the session tenant's own rclone backend, then
// SELF-TEST it (a real rclone round-trip through their config) and render the
// result, so a tenant learns immediately whether their secrets are set AND
// actually work for storing media — instead of finding out on first upload.
pub fun handle-settings-storage-post( req : request ) : <db,time,config,store,div|e> response
  val owner = session-actor(req)
  if owner == "" then forbidden("login required")
  else
    val form = query-parse(req.body)
    val conf    = field-of(form, "rclone_conf")
    val archive = field-of(form, "archive_remote").trim
    val pubrem  = field-of(form, "public_remote").trim
    val urlbase = field-of(form, "public_url_base").trim
    if archive == "" || pubrem == "" then
      bad-request("archive and public remotes are both required")
    elif has-ctl(archive) || has-ctl(pubrem) || has-ctl(urlbase) then
      // The remote targets are single rclone arguments; a newline/CR could
      // smuggle a second token into the argv we hand rclone.
      bad-request("remote targets must be a single line")
    elif !valid-remote-target(archive) || !valid-remote-target(pubrem) then
      // Both must be NAMED-remote references ("name:path") defined in the
      // tenant's own config — never a bare local path, a ":local:"-style
      // connection string, or a "-flag". Otherwise a tenant could point a
      // remote at the daemon's filesystem (rcat/cat as the service user).
      bad-request("remotes must reference a named rclone remote like archive:path, " ++
                  "not a local path or connection string")
    elif local-backend(conf) then
      // Reject local/alias backends in the config too: a named remote of
      // type=local (or alias to one) would re-open the same filesystem hole.
      // Tenants store to CLOUD backends (drive, s3, b2, crypt-over-cloud, …).
      bad-request("local/alias rclone backends are not allowed; use a cloud remote")
    elif conf.count > 65536 then
      bad-request("rclone config is too large (64 KiB max)")
    else
      save-tenant-store(owner, conf, archive, pubrem, urlbase)
      render-storage-result(req, owner)

// POST /settings/storage/test — re-run the self-test against the tenant's
// already-SAVED config (e.g. to confirm credentials still work later). Does
// not save anything.
pub fun handle-settings-storage-test( req : request ) : <db,config,store,div|e> response
  val owner = session-actor(req)
  if owner == "" then forbidden("login required")
  else render-storage-result(req, owner)

// Load the tenant's saved storage, run the archive + public self-tests, and
// render the settings page with the verdict banner. Shared by save + re-test.
fun render-storage-result( req : request, owner : url ) : <db,config,store,div|e> response
  val w = get-page-width()
  val sf = load-storage-fields(owner)
  val admin = is-admin-session(req)
  val (arch, pubr) = match load-tenant-store(owner)
    Nothing  -> ("not configured", "not configured")
    Just(ts) -> (status-of(ts.self-test-archive), status-of(ts.self-test-pubrem))
  ok-html(render-settings-form(w, "storage", sf.rclone-conf, sf.archive,
                               sf.pubrem, sf.url-base, admin, w, arch, pubr))
    .with-header("Cache-Control", "no-store")

// Map a self-test result to a display status: "" (success) → "ok"; any
// non-empty reason is passed through verbatim for the banner to show.
fun status-of( r : string ) : string
  if r == "" then "ok" else r

fun saved-param( q : string ) : div string
  query-parse(q).filter(fn(p) p.fst == "saved").head.map(fn(p) p.snd).default("")

fun field-of( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else field-of(rest, k)

// True iff `s` contains a CR or LF (would break a single-arg rclone target).
fun has-ctl( s : string ) : bool
  s.list.any(fn(c) c == '\n' || c == '\r')

// A safe rclone target references a NAMED remote: "<name>:<path>" where
// <name> starts alphanumeric and is [A-Za-z0-9_- ], and the whole thing has
// no ".." path traversal. This rejects bare local paths ("/etc", "./x"),
// connection strings (":local:..."), and flag-like tokens ("-x:...").
fun valid-remote-target( s : string ) : bool
  match s.split(":")
    Cons(name, Cons(_, _)) ->
      name != "" && starts-alnum(name) &&
      name.list.all(is-remote-name-char) && !s.contains("..")
    _ -> False

fun starts-alnum( s : string ) : bool
  match s.list
    Cons(c, _) -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    Nil        -> False

fun is-remote-name-char( c : char ) : bool
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c == '-' || c == '_' || c == ' '

// True iff the rclone config declares a local/alias backend (which could read
// or write the daemon's filesystem). Space-insensitive scan so "type = local"
// and "type=local" both match.
fun local-backend( conf : string ) : bool
  val flat = conf.to-lower.replace-all(" ", "")
  flat.contains("type=local") || flat.contains("type=alias")
