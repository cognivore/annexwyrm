// annexwyrm/web/handler/actor — GET /users/<u>
//
// Content negotiation:
//   Accept: application/activity+json (or ld+json) → JSON-LD
//   else                                            → HTML profile

module web/handler/actor

import core/types
import core/json
import core/url        // page-param
import effects/db
import effects/config
import ap/actor
import web/prefs
import web/server
import web/html/actor
import web/html/home   // home-row, items-per-page

pub fun handle-actor( req : request, u : string )
  : <db,config,div|e> response
  match load-local-actor-by-username(u)
    Nothing -> not-found("no such user")
    Just(a) ->
      if prefers-jsonld(req) then
        ok-jsonld(json/show(ap-actor/to-json(a)))
      else
        // The user's FULL archive, paginated (newest first), same page size
        // as the home feed. Clamp ?page= into [1, pages].
        val size = items-per-page
        val total = count-user-items(a.id)
        val pages = if total <= 0 then 1 else 1 + (total - 1) / size
        val req-page = page-param(req.query)
        val page = if req-page < 1 then 1 elif req-page > pages then pages else req-page
        val offset = (page - 1) * size
        ok-html(render-actor-page(a, user-items(a.id, size, offset),
                                  page, total, size, get-page-width()))

// Load a local tenant's actor row by username. Nothing when there is no such
// local actor (the handler then 404s — multitenant: many local actors exist,
// so a missing username is a real not-found, not a misconfiguration).
pub fun load-local-actor-by-username( u : string ) : <db,config|e> maybe<ap-actor>
  val rows = query(
    "SELECT id, username, name, summary, icon_url, inbox, outbox, " ++
    "followers, following, COALESCE(shared_inbox, ''), public_key_pem, " ++
    "manually_approves, discoverable FROM actor WHERE local = 1 AND username = ? LIMIT 1",
    [txt(u)]
  )
  match rows
    Nil -> Nothing
    Cons(r, _) ->
      Just(Ap-actor(
        id                 = text(r.col(0)),
        kind               = AkPerson,
        preferred-username = text(r.col(1)),
        name               = text(r.col(2)),
        summary            = text(r.col(3)),
        icon-url           = text(r.col(4)),
        inbox              = text(r.col(5)),
        outbox             = text(r.col(6)),
        followers          = text(r.col(7)),
        following          = text(r.col(8)),
        shared-inbox       = text(r.col(9)),
        public-key-id      = text(r.col(0)) ++ "#main-key",
        public-key-pem     = text(r.col(10)),
        manually-approves  = int-bool(r.col(11)),
        discoverable       = int-bool(r.col(12))
      ))

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun int-bool( v : sql-value ) : bool
  match v { SqlInt(n) -> n != 0; _ -> False }

fun intval( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(99); _ -> 99 }

// Total items owned by this tenant (drives the profile's page count).
fun count-user-items( owner-id : url ) : db int
  query("SELECT COUNT(*) FROM item WHERE owner_id = ?", [txt(owner-id)])
    .first-int.default(0)

// One page of this tenant's FULL archive, newest first, as home-rows. The
// `owner` field is left "" so the profile's rows don't repeat "by <user>".
fun user-items( owner-id : url, size : int, offset : int ) : db list<home-row>
  query(
    "SELECT id, name, object_type, COALESCE(rating,99), " ++
    "COALESCE(in_reply_to,''), published_at, COALESCE(file_published,0) " ++
    "FROM item WHERE owner_id = ? ORDER BY published_at DESC LIMIT ? OFFSET ?",
    [txt(owner-id), num(size), num(offset)]
  ).map(fn(r) Home-row(
    id             = text(r.col(0)),
    name           = text(r.col(1)),
    kind           = text(r.col(2)),
    rating         = intval(r.col(3)),
    in-reply-to    = text(r.col(4)),
    published      = text(r.col(5)),
    file-published = intval(r.col(6)) != 0,
    owner          = ""
  ))
