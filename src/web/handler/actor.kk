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
import web/server
import web/html/actor

pub fun handle-actor( req : request, u : string )
  : <db,config,div|e> response
  if u != get-local-username() then not-found("no such user")
  else
    val a = load-local-actor()
    if prefers-jsonld(req)
      then ok-jsonld(json/show(ap-actor/to-json(a)))
      else ok-html(render-actor-page(a, recent-items()))

// Load the canonical local actor row from the DB.
pub fun load-local-actor() : <db,config|e> ap-actor
  val rows = query(
    "SELECT id, username, name, summary, icon_url, inbox, outbox, " ++
    "followers, following, COALESCE(shared_inbox, ''), public_key_pem, " ++
    "manually_approves, discoverable FROM actor WHERE local = 1 LIMIT 1",
    []
  )
  match rows
    Cons(r, _) ->
      Ap-actor(
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
      )
    Nil ->
      // Should never happen post-install; render a placeholder.
      build-local-actor(get-base-url(), get-local-username(), "", "", "")

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun int-bool( v : sql-value ) : bool
  match v { SqlInt(n) -> n != 0; _ -> False }

// Up to 10 most recent public items for the profile sidebar.
fun recent-items() : db list<recent-row>
  val rows = query(
    "SELECT id, name, object_type, published_at FROM item " ++
    "WHERE privacy IN ('public','followers','unlisted') " ++
    "ORDER BY published_at DESC LIMIT 10",
    []
  )
  rows.map(fn(r) Recent-row(
    id        = text(r.col(0)),
    name      = text(r.col(1)),
    kind      = text(r.col(2)),
    published = text(r.col(3))
  ))
