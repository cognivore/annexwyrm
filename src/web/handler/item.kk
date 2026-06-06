// annexwyrm/web/handler/item — GET /items/<id> + POST /items/<id>/publish-file.

module web/handler/item

import core/types
import core/json
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/store
import ap/object
import ap/outbox
import ap/persist
import annex/item
import annex/publish
import web/server
import web/html/item
import web/html/edit

// Every item is always public: the review renders to ANYONE. There is no
// owner-only item view and no 404-for-private branch — the only thing that
// is gated is the file blob, and that is reflected on the page (archived vs
// published download link), not in the route's authorization.
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
        val owner = is-owner-session(req)
        ok-html(render-item-page(it, likes, shares, owner, tags))

// POST /items/<id>/publish-file — open the archived file to the public.
// Owner-gated, idempotent, and one-way for v1: it copies the blob to the
// public remote, mints + stores the download URL, and emits an Update.
pub fun handle-item-publish-file( req : request, id : string )
  : <db,time,rng,log,config,store,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        // Idempotent: a second publish-file is a harmless no-op, NOT a
        // double Update. Re-posting just redirects to the item.
        if it.file-published then
          see-other("/items/" ++ id)
        else
          val slug = id-tail(full-id)
          // The bytes are not in memory; fetch them back from the archive.
          match blob-get(Blob-loc(get-archive-remote(), slug))
            Nothing ->
              error("publish-file/archive-get-failed",
                [("remote", get-archive-remote()), ("slug", slug)])
              server-error("publish-file failed: could not read archived blob")
            Just(bytes) ->
              if publish-file-blob(it, slug, bytes) then
                see-other("/items/" ++ id)
              else
                server-error("public put failed: blob could not be published to " ++
                             get-public-remote())

// GET /items/<id>/edit — the owner's edit form, pre-filled with the
// item's current review metadata. Owner-gated; anonymous visitors and
// non-owners are forbidden (the form is the only way to mutate a review).
pub fun handle-item-edit-form( req : request, id : string )
  : <db,config|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) -> ok-html(render-edit-form(it, id, load-item-tags(full-id)))

// POST /items/<id>/edit — apply a metadata edit and federate an Update.
// Owner-gated. Body is application/x-www-form-urlencoded (no file part).
// Each field defaults to the item's CURRENT value when ABSENT from the
// form, but a present-but-empty field is an intentional clear (e.g.
// blanking the title back to "(untitled)"). The file blob and its
// publication state are never touched here.
pub fun handle-item-edit-post( req : request, id : string )
  : <db,time,rng,log,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        val form = query-parse(req.body)
        val name = form-lookup(form, "name").default(it.name)
        val summary = form-lookup(form, "summary").default(it.summary)
        val content = form-lookup(form, "content").default(it.content)
        val rating = clamp-rating(
          form-lookup(form, "rating").default(it.rating.show).parse-int.default(it.rating))
        val in-reply-to = form-lookup(form, "in_reply_to").default(it.in-reply-to)
        val now = now-iso()
        // Tags: present (even empty) ⇒ replace with the parsed set; absent ⇒
        // keep the current set. (load-item-tags here reads them BEFORE
        // save-item's REPLACE; ship-edited-item then writes the final set
        // AFTER save-item, then federates it.)
        val new-tags = match form-lookup(form, "tags")
          Just(tval) -> parse-tags(tval)
          Nothing    -> load-item-tags(full-id)
        ship-edited-item(
          edit-item-fields(it, name, summary, content, rating, in-reply-to, now),
          new-tags)
        info("item/edited", [("id", full-id), ("rating", rating.show)])
        see-other("/items/" ++ id)

// Effectful tail for an edit: persist the already-built item and federate
// the Update. The item is a PARAMETER (not a local capture) and this
// returns () — the koka#654-safe shape shared with ship-published-item.
fun ship-edited-item( it : annex-item, tags : list<string> )
  : <db,time,rng,log,config,div|e> ()
  save-item(it)                 // self-preserves the OLD tags…
  save-item-tags(it.id, tags)   // …which we then override with the edit's set
  emit-update(it)               // emit-update reads item_tag → federates `tags`

// Look up a form field, distinguishing "absent" (Nothing → keep current)
// from "present but empty" (Just "" → intentional clear).
fun form-lookup( fs : list<(string,string)>, k : string ) : maybe<string>
  match fs
    Nil -> Nothing
    Cons((k0,v), rest) -> if k0 == k then Just(v) else form-lookup(rest, k)

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
pub fun publish-file-blob( it : annex-item, slug : string, bytes : string )
  : <db,time,rng,log,config,store,div|e> bool
  val public-loc = Blob-loc(get-public-remote(), slug)
  blob-put(public-loc, bytes)
  if !blob-has(public-loc) then
    error("publish-file/public-put-failed",
      [("remote", get-public-remote()), ("slug", slug)])
    False
  else
    match blob-public-url(public-loc)
      Nothing ->
        error("publish-file/link-mint-failed",
          [("remote", get-public-remote()), ("slug", slug)])
        False
      Just(view) ->
        val now = now-iso()
        val pub-target = get-public-remote() ++ "/" ++ slug
        ship-published-item(build-published-item(it, pub-target, view, now))
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

// ----------------------------------------------------------------------
//  Auth
// ----------------------------------------------------------------------

// True iff the request's `Cookie: session=…` resolves to a valid session
// whose actor is the local actor.
pub fun is-owner-session( req : request ) : db bool
  val tok = cookie-value(req.header("cookie").default(""), "session")
  if tok == "" then False
  else
    val rows = query(
      "SELECT 1 FROM session s JOIN actor a ON a.id = s.actor_id " ++
      "WHERE s.token = ? AND a.local = 1 AND datetime(s.expires_at) > datetime('now')",
      [txt(tok)]
    )
    match rows { Cons(_,_) -> True; _ -> False }

fun cookie-value( header-val : string, name : string ) : string
  header-val.split(";").map(fn(s) s.trim).flatmap(fn(p)
    match p.starts-with(name ++ "=")
      Just(slc) -> [slc.string]
      Nothing   -> []
  ).head.default("")
