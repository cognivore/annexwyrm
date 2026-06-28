// annexwyrm/web/handler/item — GET /items/<id> + POST /items/<id>/publish-file.

module web/handler/item

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/store
import effects/crypto
import ap/object
import ap/outbox
import ap/persist
import annex/item
import annex/publish
import annex/storage   // tenant-store, load-tenant-store, archive-loc, public-loc
import web/prefs
import web/session     // is-tenant-session, is-owner-of
import web/server
import web/multipart
import web/html/item
import web/html/edit
import interp/str   // byte-count: a total C-backed primitive (see upload.kk)

// Every item is always public: the review renders to ANYONE. There is no
// owner-only item view and no 404-for-private branch — the only thing that
// is gated is the file blob, and that is reflected on the page (archived vs
// published download link), not in the route's authorization. The edit /
// publish CONTROLS, though, show only to the item's OWNER (is-owner-of), not
// to every logged-in tenant — a peer can read and download, but not mutate.
pub fun handle-item( req : request, id : string )
  : <db,config,div|e> response
  val full-id = get-base-url() ++ "/items/" ++ id
  match load-item(full-id)
    Nothing -> not-found("no such item")
    Just(it) ->
      val tags = load-item-tags(full-id)
      if prefers-jsonld(req) then
        val followers = it.owner ++ "/followers"
        val obj = item-to-ap-object(it, followers, tags)
        ok-jsonld(json/show(ap-object/to-json(obj)))
      else
        val likes = count-likes(full-id)
        val shares = count-shares(full-id)
        val owner = is-owner-of(req, it.owner)
        ok-html(render-item-page(it, likes, shares, owner, tags, get-page-width()))

// POST /items/<id>/publish-file — open the archived file to the public.
// Gated to the item's OWNER, idempotent, and one-way for v1: it copies the
// blob to the owner's public remote, mints + stores the download URL, and
// emits an Update. The owner's own storage config backs every blob op.
pub fun handle-item-publish-file( req : request, id : string )
  : <db,time,rng,log,config,store,div|e> response
  val full-id = get-base-url() ++ "/items/" ++ id
  match load-item(full-id)
    Nothing -> not-found("no such item")
    Just(it) ->
      val who = session-actor(req)
      if who == "" then forbidden("login required")
      elif who != it.owner then forbidden("not your item")
      // Idempotent: a second publish-file is a harmless no-op, NOT a
      // double Update. Re-posting just redirects to the item.
      elif it.file-published then
        see-other("/items/" ++ id)
      else match load-tenant-store(it.owner)
        Nothing -> server-error("the owner has no storage configured")
        Just(ts) ->
          val slug = id-tail(full-id)
          // The bytes are not in memory; fetch them back from the archive.
          match blob-get(ts.archive-loc(slug))
            Nothing ->
              error("publish-file/archive-get-failed",
                [("remote", ts.archive), ("slug", slug)])
              server-error("publish-file failed: could not read archived blob")
            Just(bytes) ->
              if publish-file-blob(it, slug, bytes, ts) then
                see-other("/items/" ++ id)
              else
                server-error("public put failed: blob could not be published to " ++
                             ts.pubrem)

// GET /items/<id>/file — TENANT private download (the cross-tenant sharing
// rule). Streams the blob from the encrypted ARCHIVE remote (rclone decrypts
// on the way out) through this authenticated route. ANY logged-in tenant may
// pull ANY item's archived bytes — that is the "tenants view each other's
// files" promise — but the decrypt always runs through the OWNER's storage
// config (load-tenant-store(it.owner)), never the viewer's. Anonymous
// requests are forbidden: an archived file leaks nothing to the logged-out
// public; only the published public link (external) is world-reachable.
pub fun handle-item-file( req : request, id : string )
  : <db,config,store,div|e> response
  if !is-tenant-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        if !(it.byte-size > 0 || it.remotes.is-cons) then not-found("no file")
        else match load-tenant-store(it.owner)
          Nothing -> not-found("file not found in archive")
          Just(ts) ->
            val slug = id-tail(full-id)
            match blob-get(ts.archive-loc(slug))
              Nothing -> not-found("file not found in archive")
              Just(bytes) ->
                val ct = if it.media-type == "" then "application/octet-stream"
                         else it.media-type
                ok-binary(ct, bytes)
                  .with-header("Content-Disposition",
                    "attachment; filename=\"" ++ safe-filename(it, slug) ++ "\"")

// A header-safe download filename: keep only plain word chars, dot, dash,
// underscore and space (so no quote / CR / LF can break the
// Content-Disposition header), fall back to the slug when nothing's left.
fun safe-filename( it : annex-item, slug : string ) : string
  val keep = it.name.list.filter(fn(c)
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
    (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' || c == ' '
  ).string.trim
  if keep == "" then slug else keep

// GET /items/<id>/edit — the owner's edit form, pre-filled with the
// item's current review metadata. Owner-gated; anonymous visitors and
// non-owners are forbidden (the form is the only way to mutate a review).
pub fun handle-item-edit-form( req : request, id : string )
  : <db,config|e> response
  val full-id = get-base-url() ++ "/items/" ++ id
  match load-item(full-id)
    Nothing -> not-found("no such item")
    Just(it) ->
      val who = session-actor(req)
      if who == "" then forbidden("login required")
      elif who != it.owner then forbidden("not your item")
      else ok-html(render-edit-form(it, id, load-item-tags(full-id), get-page-width()))

// POST /items/<id>/edit — apply a review edit AND any file change, then
// federate a single Update. Owner-gated. Body is multipart/form-data so the
// form can carry an OPTIONAL file part alongside the text fields — the edit
// page is the one place to manage everything about an item, blob included.
//
// Text fields: present-but-empty is an intentional clear (e.g. blanking the
// title to "(untitled)"); the form always submits them, so the per-field
// default only matters defensively.
//
// File intent, in one place (see apply-file-change):
//   * attach a file to a file-less review, or replace an existing blob;
//   * publish it now (public download) or keep it archived (encrypted only);
//   * later flip a published file back to archived, or an archived one public.
// The `publish_file` checkbox carries the DESIRED public state; an attached
// file part optionally (re)places the bytes. A file is ALWAYS archived first
// (encrypted remote, verified) and is only ever on disk in rclone — never the
// server's data dir. Retracting a public file DELETES it from the public
// remote, so the download truly stops (not just a hidden link).
pub fun handle-item-edit-post( req : request, id : string )
  : <db,time,rng,log,config,store,crypto,div|e> response
  val full-id = get-base-url() ++ "/items/" ++ id
  match load-item(full-id)
    Nothing -> not-found("no such item")
    Just(it) ->
      val who = session-actor(req)
      if who == "" then forbidden("login required")
      elif who != it.owner then forbidden("not your item")
      else
        val ct = req.header("content-type").default("")
        match parse-multipart(ct, req.body)
          Nothing -> bad-request("expected multipart/form-data")
          Just(parts) ->
            val name = field(parts, "name").default(it.name)
            val summary = field(parts, "summary").default(it.summary)
            val content = field(parts, "content").default(it.content)
            val rating = clamp-rating(
              field(parts, "rating").default(it.rating.show).parse-int.default(it.rating))
            val in-reply-to = field(parts, "in_reply_to").default(it.in-reply-to)
            val want-public = field(parts, "publish_file").is-just
            // Tags: present (even empty) ⇒ replace with the parsed set; absent
            // ⇒ keep the current set.
            val new-tags = match field(parts, "tags")
              Just(tval) -> parse-tags(tval)
              Nothing    -> load-item-tags(full-id)
            val now = now-iso()
            val slug = id-tail(full-id)
            // The owner's storage (Nothing if unconfigured) backs any blob op.
            // A text-only edit of a file-less review needs none of it, so we
            // pass it as maybe and only the blob branches require it. Resolve
            // it BEFORE building `base`: an effectful bind between building the
            // annex-item value struct and consuming it would capture it in an
            // mlift lambda and trip koka#654.
            val ts-opt = load-tenant-store(it.owner)
            val base = edit-item-fields(it, name, summary, content, rating, in-reply-to, now)
            if apply-file-change(base, it.file-published, files(parts).head, want-public, slug, now, new-tags, ts-opt) then
              info("item/edited", [("id", full-id), ("rating", rating.show)])
              see-other("/items/" ++ id)
            else
              server-error("file operation failed; the review was not changed")

// Apply the edit's FILE intent on top of the (already text-edited) `base`,
// PERSIST + federate the result (a single Update via ship-edited-item), and
// return True — or False if a mandatory store op failed (caller → 5xx,
// nothing saved). It ships internally rather than returning the built item
// because returning an annex-item value struct from an effectful body trips
// koka#654; the struct is built purely and handed to the ()-returning ship.
//
//   * a new file part      ⇒ (re)archive the bytes, then publish or not
//   * no file, has a blob  ⇒ toggle publication to match `want-public`
//   * no file, file-less   ⇒ nothing to (un)publish; just the text edit
//
// `was-published` is the pre-edit publication state (consulted so a replaced /
// retracted public blob is deleted from the public remote). It is a bool, NOT
// the whole pre-edit item: capturing a SECOND annex-item value struct across
// an effectful bind trips koka#654 ("multiple value type fields"). Only `base`
// (one annex-item) may flow through the effectful body.
fun apply-file-change(
    base : annex-item, was-published : bool, new-file : maybe<mpart>,
    want-public : bool, slug : string, now : iso-time, tags : list<string>,
    ts-opt : maybe<tenant-store>
  ) : <db,time,rng,log,config,store,crypto,div|e> bool
  match new-file
    Just(f) ->
      // A new/replacement blob always needs the owner's storage.
      match ts-opt
        Nothing ->
          error("edit/no-storage", [("slug", slug)])
          False
        Just(ts) -> apply-new-file(base, was-published, f, want-public, slug, now, tags, ts)
    Nothing ->
      // No new bytes. The storage-free cases first: a file-less review, or a
      // toggle that doesn't change the public state — neither touches a blob.
      if !(base.byte-size > 0 || base.remotes.is-cons) then
        ship-edited-item(base, tags)
        True
      elif want-public == was-published then
        ship-edited-item(base, tags)
        True
      else match ts-opt
        Nothing ->
          error("edit/no-storage", [("slug", slug)])
          False
        Just(ts) -> apply-toggle(base, want-public, slug, now, tags, ts)

// New/replacement blob: archive it (mandatory + verified), then publish or
// keep archived — all against `ts` (the owner's backend).
fun apply-new-file(
    base : annex-item, was-published : bool, f : mpart, want-public : bool,
    slug : string, now : iso-time, tags : list<string>, ts : tenant-store
  ) : <db,time,rng,log,config,store,crypto,div|e> bool
  val media = if f.media-type == "" then "application/octet-stream" else f.media-type
  val sha = b64-encode(sha256(f.body))
  val byte-size = byte-count(f.body)
  val archive-loc = ts.archive-loc(slug)
  blob-put(archive-loc, f.body)
  if !blob-has(archive-loc) then
    error("edit/archive-put-failed", [("remote", ts.archive), ("slug", slug)])
    False
  else
    val archive-remote = Item-remote(
      RkRclone, ts.archive ++ "/" ++ slug, media,
      "archive (encrypted)", False, 0)
    val archived = with-new-blob(base, guess-kind(media), media, byte-size, sha, [archive-remote])
    if want-public then
      publish-and-ship(archived, slug, f.body, now, tags, ts)
    elif was-published && !revoke-public(slug, ts) then
      // Replacing a previously-published file with a private one, but the
      // old public copy could NOT be verifiably deleted — fail the edit
      // rather than claim "private" while the blob stays downloadable. The
      // item is left untouched (still published), so the owner can retry.
      False
    else
      ship-edited-item(archived, tags)
      True

// No new bytes, but the public state flips. Both directions need `ts`.
fun apply-toggle(
    base : annex-item, want-public : bool, slug : string, now : iso-time,
    tags : list<string>, ts : tenant-store
  ) : <db,time,rng,log,config,store,div|e> bool
  if want-public then
    // archived → published: the bytes aren't in memory; read them back.
    match blob-get(ts.archive-loc(slug))
      Nothing ->
        error("edit/archive-get-failed", [("remote", ts.archive), ("slug", slug)])
        False
      Just(bytes) -> publish-and-ship(base, slug, bytes, now, tags, ts)
  elif revoke-public(slug, ts) then
    // published → archived: the public blob was VERIFIABLY deleted (revokes
    // the download); now clear the minted URLs + drop the public mirror.
    ship-edited-item(archive-only-item(base, now), tags)
    True
  else
    // The public blob could not be verifiably deleted — do NOT mark the item
    // private (that would claim revocation while the file stays downloadable).
    // Fail the edit; the item stays published + consistent.
    False

// Delete the public blob and VERIFY it is actually gone, returning False if it
// still resolves afterwards. Un-publishing's security promise is REVOCATION,
// not just hiding the link — a silent `rclone deletefile` failure (transient
// Drive/network error) would otherwise leave the file downloadable while the
// DB + federation say "private". The caller turns False into a 5xx and leaves
// the item published, so the visible state never lies about reachability.
//
// DATA-SAFETY GUARD: we only ever delete the PUBLIC mirror, and only once the
// encrypted-archive (private) copy is verifiably present — so a delete can
// only remove a redundant copy, never the last one. This also fails safe if
// the public remote were mis-configured equal to the archive remote. (Answer
// to "do you ever delete a file with no private counterpart?" — no, refused.)
fun revoke-public( slug : string, ts : tenant-store ) : <log,store|e> bool
  if ts.pubrem == ts.archive then
    error("edit/refuse-delete-remotes-equal",
      [("remote", ts.pubrem), ("slug", slug)])
    False
  elif !blob-has(ts.archive-loc(slug)) then
    error("edit/refuse-delete-no-archive",
      [("archive", ts.archive), ("slug", slug)])
    False
  else
    val loc = ts.pubrem-loc(slug)
    blob-del(loc)
    if blob-has(loc) then
      error("edit/public-delete-failed",
        [("remote", ts.pubrem), ("slug", slug)])
      False
    else
      True

fun guess-kind( media : string ) : object-kind
  match media-type/parse(media)
    Just(mt) -> object-kind/from-media(mt)
    Nothing  -> OkDocument

// Effectful tail for an edit: persist the already-built item and federate
// the Update. The item is a PARAMETER (not a local capture) and this
// returns () — the koka#654-safe shape shared with ship-published-item.
fun ship-edited-item( it : annex-item, tags : list<string> )
  : <db,time,rng,log,config,div|e> ()
  save-item(it)                 // self-preserves the OLD tags…
  save-item-tags(it.id, tags)   // …which we then override with the edit's set
  emit-update(it)               // emit-update reads item_tag → federates `tags`

// ----------------------------------------------------------------------
//  The publish-file body — shared by upload-with-publish_file and the
//  later /publish-file action.
//
//  Returns True on success, False on a verified failure (the caller turns
//  False into a 5xx and leaves the file archived). Per koka#654, this
//  effectful body NEVER returns the freshly-built `annex-item` value
//  struct; a pure builder makes it and `ship-published-item` consumes it
//  as a PARAMETER and returns () (mirroring ap/outbox's emit-*/ship-*).
//
//  Bytes are a parameter so the upload-inline case uses f.body directly
//  and the later action uses the bytes read back from the archive.
// ----------------------------------------------------------------------
pub fun publish-file-blob( it : annex-item, slug : string, bytes : string, ts : tenant-store )
  : <db,time,rng,log,config,store,div|e> bool
  val public-loc = ts.pubrem-loc(slug)
  blob-put(public-loc, bytes)
  if !blob-has(public-loc) then
    error("publish-file/public-put-failed",
      [("remote", ts.pubrem), ("slug", slug)])
    False
  else
    match blob-public-url(public-loc)
      Nothing ->
        error("publish-file/link-mint-failed",
          [("remote", ts.pubrem), ("slug", slug)])
        False
      Just(view) ->
        val now = now-iso()
        val pub-target = ts.pubrem ++ "/" ++ slug
        ship-published-item(build-published-item(it, pub-target, view, now))
        True

// Edit-path publish: copy bytes to the public remote, verify, mint the URL,
// build the published item, and ship it WITH the edit's tag set (one Update).
// Returns False on a verified store / mint failure. Mirrors publish-file-blob
// but routes through ship-edited-item so the edit's tags are written too.
// Per the koka#654 rule, the freshly-built item is never RETURNED from this
// effectful body — it is built purely and handed to the ()-returning ship.
fun publish-and-ship(
    it : annex-item, slug : string, bytes : string, now : iso-time,
    tags : list<string>, ts : tenant-store
  ) : <db,time,rng,log,config,store,div|e> bool
  val public-loc = ts.pubrem-loc(slug)
  blob-put(public-loc, bytes)
  if !blob-has(public-loc) then
    error("publish-file/public-put-failed",
      [("remote", ts.pubrem), ("slug", slug)])
    False
  else
    match blob-public-url(public-loc)
      Nothing ->
        error("publish-file/link-mint-failed",
          [("remote", ts.pubrem), ("slug", slug)])
        False
      Just(view) ->
        ship-edited-item(
          build-published-item(it, ts.pubrem ++ "/" ++ slug, view, now),
          tags)
        True

// Pure: build the published item value struct (no effects → no mlift, so
// koka#654's value-struct-in-lambda panic cannot fire here). `pub-target`
// is the public mirror's rclone target, threaded in so this stays total.
fun build-published-item( it : annex-item, pub-target : string, view : url, now : iso-time )
  : annex-item
  val (public-url, view-url) = derive-url-forms(view)
  val public-remote = Item-remote(
    RkRclone, pub-target, it.media-type,
    "public download", True, 1
  )
  publish-file-item(it, public-url, view-url, now, it.remotes ++ [public-remote])

// Effectful tail: persist + federate an already-built item. The item is a
// PARAMETER (not a local capture), and this returns () — exactly the shape
// that keeps koka#654's mlift-capture panic clear.
fun ship-published-item( it : annex-item )
  : <db,time,rng,log,config,div|e> ()
  save-item(it)
  emit-update(it)

// Derive the (download, viewer) URL pair from rclone's minted link.
// gdrive: "https://drive.google.com/open?id=<ID>" → the download form is
// "https://drive.google.com/uc?export=download&id=<ID>", the viewer stays.
// Anything else (the hermetic constructed URL): both forms equal `view`.
fun derive-url-forms( view : url ) : (url, url)
  match view.find("open?id=")
    Nothing -> (view, view)
    Just(slc) ->
      val gid = slc.after.string
      val dl = "https://drive.google.com/uc?export=download&id=" ++ gid
      (dl, view)

// ----------------------------------------------------------------------
//  DB helpers
// ----------------------------------------------------------------------

pub fun load-item( id : url ) : db maybe<annex-item>
  val rows = query(
    "SELECT id, owner_id, object_type, COALESCE(name,''), " ++
    "COALESCE(summary,''), COALESCE(content,''), COALESCE(media_type,''), " ++
    "COALESCE(byte_size,0), COALESCE(sha256,''), " ++
    "COALESCE(rating, 99), COALESCE(in_reply_to, ''), " ++
    "COALESCE(file_published,0), COALESCE(file_public_url,''), " ++
    "COALESCE(file_view_url,''), " ++
    "published_at, updated_at " ++
    "FROM item WHERE id = ?",
    [txt(id)]
  )
  match rows
    Nil -> Nothing
    Cons(r, _) ->
      val rrs = load-remotes(id)
      Just(Annex-item(
        id              = text(r.col(0)),
        owner           = text(r.col(1)),
        kind            = object-kind/parse(text(r.col(2))).default(OkDocument),
        name            = text(r.col(3)),
        summary         = text(r.col(4)),
        content         = text(r.col(5)),
        media-type      = text(r.col(6)),
        byte-size       = int(r.col(7)),
        sha256-hex      = text(r.col(8)),
        rating          = clamp-rating(int(r.col(9))),
        in-reply-to     = text(r.col(10)),
        file-published  = int(r.col(11)) != 0,
        file-public-url = text(r.col(12)),
        file-view-url   = text(r.col(13)),
        published-at    = text(r.col(14)),
        updated-at      = text(r.col(15)),
        remotes         = rrs
      ))

fun load-remotes( item-id : url ) : db list<item-remote>
  val rows = query(
    "SELECT kind, target, COALESCE(media_type,''), COALESCE(label,''), " ++
    "published, sort_order FROM item_remote WHERE item_id = ? ORDER BY sort_order",
    [txt(item-id)]
  )
  rows.map(fn(r) Item-remote(
    kind       = remote-kind/parse(text(r.col(0))).default(RkUrl),
    target     = text(r.col(1)),
    media-type = text(r.col(2)),
    label      = text(r.col(3)),
    published  = int(r.col(4)) != 0,
    sort-order = int(r.col(5))
  ))

pub fun save-item( i : annex-item ) : db ()
  // INSERT OR REPLACE deletes any existing row first, which fires ON DELETE
  // CASCADE on item_tag (and item_remote). Remotes are re-written from the
  // value struct below; tags live in a side table the struct doesn't carry,
  // so capture and restore them here. Callers that intend to CHANGE tags
  // call save-item-tags AFTER this (e.g. the edit path). Without this,
  // every re-save (edit, publish-file) would silently wipe the item's tags.
  val keep-tags = load-item-tags(i.id)
  val _ = exec(
    "INSERT OR REPLACE INTO item " ++
    "(id, owner_id, object_type, name, summary, content, " ++
    "media_type, byte_size, sha256, rating, in_reply_to, " ++
    "file_published, file_public_url, file_view_url, " ++
    "published_at, updated_at) " ++
    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    [txt(i.id), txt(i.owner), txt(i.kind.show),
     txt(i.name), txt(i.summary), txt(i.content), txt(i.media-type),
     num(i.byte-size), txt(i.sha256-hex),
     rating-cell(i.rating), reply-cell(i.in-reply-to),
     num(if i.file-published then 1 else 0),
     url-cell(i.file-public-url), url-cell(i.file-view-url),
     txt(i.published-at), txt(i.updated-at)]
  )
  val _ = exec("DELETE FROM item_remote WHERE item_id = ?", [txt(i.id)])
  i.remotes.foreach(fn(r) save-remote(i, r))
  save-item-tags(i.id, keep-tags)

fun save-remote( i : annex-item, r : item-remote ) : db ()
  val _ = exec(
    "INSERT INTO item_remote " ++
    "(item_id, kind, target, media_type, label, published, sort_order, created_at) " ++
    "VALUES (?,?,?,?,?,?,?,?)",
    [txt(i.id), txt(r.kind.show), txt(r.target), txt(r.media-type),
     txt(r.label), num(if r.published then 1 else 0),
     num(r.sort-order), txt(i.updated-at)]
  )
  ()

// NULL out unrated (sentinel) values when writing them back.
fun rating-cell( r : int ) : sql-value
  if r == rating-unrated then SqlNull else SqlInt(r)

fun reply-cell( s : string ) : sql-value
  if s == "" then SqlNull else SqlText(s)

// NULL out an empty file URL (archived items have no minted URL).
fun url-cell( s : string ) : sql-value
  if s == "" then SqlNull else SqlText(s)

// Last path segment of a full item URL. "http://x/items/abc" → "abc".
pub fun id-tail( id : url ) : string
  id.split("/").reverse.head.default(id)

fun count-likes( object-id : url ) : db int
  query("SELECT COUNT(*) FROM like_ WHERE object_id = ?", [txt(object-id)])
    .first-int.default(0)

fun count-shares( object-id : url ) : db int
  query("SELECT COUNT(*) FROM announce WHERE object_id = ?", [txt(object-id)])
    .first-int.default(0)

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun int( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(0); _ -> 0 }
