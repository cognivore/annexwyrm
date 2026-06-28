// annexwyrm/web/session — who is logged in on this request.
//
// Multitenancy's auth half. The single-tenant `is-owner-session` ("is this
// the one owner?") is replaced by a resolution of the session's actor, plus
// three precise predicates the handlers gate on:
//
//   * is-tenant-session — any logged-in local actor (upload, download a peer's
//     file, follow). The community-of-tenants surface.
//   * is-owner-of(item.owner) — the session actor IS this resource's owner
//     (edit / publish / retract MY item). Per-item authorisation.
//   * is-admin-session — the bootstrap tenant (mint invites).
//
// Lives in its own neutral module so every handler can import the checks
// without pulling in web/handler/item (which used to host them).

module web/session

import core/types
import effects/db
import web/server

// The resolved session: which local actor, and whether they are the admin.
pub value struct session-info
  actor-id : string
  username : string
  is-admin : bool

// Resolve the request's `Cookie: session=…` to a live session for a LOCAL
// actor, or Nothing. The expiry check is in SQL (datetime compare), exactly
// as the old owner check was.
pub fun current-session( req : request ) : db maybe<session-info>
  val tok = cookie-value(req.header("cookie").default(""), "session")
  if tok == "" then Nothing
  else
    val rows = query(
      "SELECT a.id, a.username, a.is_admin FROM session s " ++
      "JOIN actor a ON a.id = s.actor_id " ++
      "WHERE s.token = ? AND a.local = 1 AND datetime(s.expires_at) > datetime('now')",
      [txt(tok)]
    )
    match rows
      Cons(r, _) -> Just(Session-info(text(r.col(0)), text(r.col(1)), int(r.col(2)) != 0))
      Nil        -> Nothing

// The actor-id of the valid session, or "" if not logged in.
pub fun session-actor( req : request ) : db string
  match current-session(req)
    Just(s) -> s.actor-id
    Nothing -> ""

// True iff SOME local tenant is logged in (the cross-tenant community gate:
// upload, download any tenant's file, follow).
pub fun is-tenant-session( req : request ) : db bool
  session-actor(req) != ""

// True iff the logged-in tenant is the admin (may mint invites).
pub fun is-admin-session( req : request ) : db bool
  match current-session(req)
    Just(s) -> s.is-admin
    Nothing -> False

// True iff the session actor IS `owner` (per-item mutation gate). Empty owner
// never matches.
pub fun is-owner-of( req : request, owner : url ) : db bool
  owner != "" && session-actor(req) == owner

// Parse a single cookie value out of a `Cookie:` header.
pub fun cookie-value( header-val : string, name : string ) : string
  header-val.split(";").map(fn(s) s.trim).flatmap(fn(p)
    match p.starts-with(name ++ "=")
      Just(slc) -> [slc.string]
      Nothing   -> []
  ).head.default("")

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun int( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(0); _ -> 0 }
