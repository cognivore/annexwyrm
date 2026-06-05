// annexwyrm/web/handler/item — GET /items/<id> + POST /items/<id>/publish etc.

module web/handler/item

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import ap/object
import ap/outbox
import annex/item
import annex/publish
import web/server
import web/html/item

pub fun handle-item( req : request, id : string )
  : <db,config,div|e> response
  val full-id = get-base-url() ++ "/items/" ++ id
  match load-item(full-id)
    Nothing -> not-found("no such item")
    Just(it) ->
      if it.privacy.show == "private" && !is-owner-session(req) then
        not-found("no such item")
      elif prefers-jsonld(req) then
        val followers = it.owner ++ "/followers"
        val obj = item-to-ap-object(it, followers)
        ok-jsonld(json/show(ap-object/to-json(obj)))
      else
        val likes = count-likes(full-id)
        val shares = count-shares(full-id)
        ok-html(render-item-page(it, likes, shares))

pub fun handle-item-publish( req : request, id : string )
  : <db,time,rng,log,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        val privacy-str = "public"   // default; could be a form field
        val target = privacy/parse(privacy-str).default(ItPublic)
        val now = now-iso()
        val published = publish-item(it, target, now)
        save-item(published)
        emit-create(published)
        see-other("/items/" ++ id)

pub fun handle-item-unpublish( req : request, id : string )
  : <db,time,rng,log,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        emit-delete(it)
        val now = now-iso()
        val unpub = unpublish-item(it, now)
        save-item(unpub)
        see-other("/items/" ++ id)

pub fun handle-item-update( req : request, id : string )
  : <db,time,rng,log,config,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val full-id = get-base-url() ++ "/items/" ++ id
    match load-item(full-id)
      Nothing -> not-found("no such item")
      Just(it) ->
        emit-update(it)
        see-other("/items/" ++ id)

// ----------------------------------------------------------------------
//  DB helpers
// ----------------------------------------------------------------------

pub fun load-item( id : url ) : db maybe<annex-item>
  val rows = query(
    "SELECT id, owner_id, object_type, privacy, COALESCE(name,''), " ++
    "COALESCE(summary,''), COALESCE(content,''), COALESCE(media_type,''), " ++
    "COALESCE(byte_size,0), COALESCE(sha256,''), " ++
    "COALESCE(rating, 99), COALESCE(in_reply_to, ''), " ++
    "published_at, updated_at " ++
    "FROM item WHERE id = ?",
    [txt(id)]
  )
  match rows
    Nil -> Nothing
    Cons(r, _) ->
      val rrs = load-remotes(id)
      Just(Annex-item(
        id           = text(r.col(0)),
        owner        = text(r.col(1)),
        kind         = object-kind/parse(text(r.col(2))).default(OkDocument),
        privacy      = privacy/parse(text(r.col(3))).default(ItPrivate),
        name         = text(r.col(4)),
        summary      = text(r.col(5)),
        content      = text(r.col(6)),
        media-type   = text(r.col(7)),
        byte-size    = int(r.col(8)),
        sha256-hex   = text(r.col(9)),
        rating       = clamp-rating(int(r.col(10))),
        in-reply-to  = text(r.col(11)),
        published-at = text(r.col(12)),
        updated-at   = text(r.col(13)),
        remotes      = rrs
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
  val _ = exec(
    "INSERT OR REPLACE INTO item " ++
    "(id, owner_id, object_type, privacy, name, summary, content, " ++
    "media_type, byte_size, sha256, rating, in_reply_to, " ++
    "published_at, updated_at) " ++
    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    [txt(i.id), txt(i.owner), txt(i.kind.show), txt(i.privacy.show),
     txt(i.name), txt(i.summary), txt(i.content), txt(i.media-type),
     num(i.byte-size), txt(i.sha256-hex),
     rating-cell(i.rating), reply-cell(i.in-reply-to),
     txt(i.published-at), txt(i.updated-at)]
  )
  val _ = exec("DELETE FROM item_remote WHERE item_id = ?", [txt(i.id)])
  i.remotes.foreach(fn(r) save-remote(i, r))

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
