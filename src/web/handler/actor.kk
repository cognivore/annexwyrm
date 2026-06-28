// annexwyrm/web/handler/actor — GET /users/<u>
//
// Content negotiation:
//   Accept: application/activity+json (or ld+json) → JSON-LD
//   else                                            → HTML profile

module web/handler/actor

import core/types
import core/json
import effects/db
import effects/config
import ap/actor
import web/prefs
import web/server
import web/html/actor

pub fun handle-actor( req : request, u : string )
  : <db,config,div|e> response
  match load-local-actor-by-username(u)
    Nothing -> not-found("no such user")
    Just(a) ->
      if prefers-jsonld(req)
        then ok-jsonld(json/show(ap-actor/to-json(a)))
        else ok-html(render-actor-page(a, recent-items(a.id), get-page-width()))

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

// Up to 10 most recent items for this tenant's profile sidebar. Every item is
// public; the only filter is the owner (the profile shows that user's posts).
fun recent-items( owner-id : url ) : db list<recent-row>
  val rows = query(
    "SELECT id, name, object_type, published_at FROM item " ++
    "WHERE owner_id = ? ORDER BY published_at DESC LIMIT 10",
    [txt(owner-id)]
  )
  rows.map(fn(r) Recent-row(
    id        = text(r.col(0)),
    name      = text(r.col(1)),
    kind      = text(r.col(2)),
    published = text(r.col(3))
  ))
