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
import effects/time
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
  val tok = session-token(req)
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

// ----------------------------------------------------------------------
//  Session lifetime — the ONE place that knows how long a login lasts.
//
//  Two years. A browser session lives in two coupled places: the `session`
//  row (`expires_at`, the authority) and the `Set-Cookie` the browser keeps
//  (`Max-Age`, which only has to be long enough for the browser to still
//  present the token). Both are minted from `session-ttl-seconds` so they
//  cannot drift. Browsers cap a single Set-Cookie at 400 days (RFC 6265bis;
//  Chrome, Firefox and Safari all enforce it), so the two years are reached
//  by RENEWAL: `refresh-session` re-plants the cookie and pushes the row's
//  expiry out again on the first authenticated request of each day. A
//  device that visits at least once every 400 days therefore never sees the
//  login form again; one idle for two years is logged out by the row.
// ----------------------------------------------------------------------

pub fun session-ttl-seconds() : int
  60 * 60 * 24 * 730                           // 2 years

// Renew when the row has less than (TTL - 1 day) left, i.e. at most once a
// day per session, never on every page view.
fun renew-threshold-seconds() : int
  session-ttl-seconds() - 60 * 60 * 24

// The `expires_at` for a session minted or renewed right now.
pub fun session-expiry() : time iso-time
  iso-from-unix(now-unix() + session-ttl-seconds())

// The full `Set-Cookie` value for session token `tok`.
//   * SameSite=Strict (not Lax): the cookie authorises only owner mutations
//     (upload/edit/publish/follow/logout) and never needs to ride a
//     cross-site request; Strict means no browser attaches it to ANY
//     cross-origin request, closing the CSRF gap Lax leaves for cross-site
//     POSTs. HttpOnly keeps it out of JS.
//   * Secure only over HTTPS — see `secure-attr`.
pub fun session-cookie( req : request, tok : string ) : string
  "session=" ++ tok ++ "; Path=/; HttpOnly; SameSite=Strict; Max-Age="
    ++ session-ttl-seconds().show ++ secure-attr(req)

// "; Secure" iff this request arrived over HTTPS. Caddy in front of the
// daemon sets X-Forwarded-Proto; the public site pins it to `https`, the
// local http:// dev site to `http`. Secure means "send only over HTTPS", so
// adding it unconditionally would silently break login on the
// http://annexwyrm.localhost dev path (the browser would drop the cookie) —
// exactly the trap the previous CTO hit. Gate it on the scheme.
pub fun secure-attr( req : request ) : string
  if req.header("x-forwarded-proto").default("") == "https"
    then "; Secure" else ""

// Sliding renewal, applied by the dispatcher to EVERY response. No-ops when
// the response already manages the cookie itself (login, register, logout
// all set `Set-Cookie`), when the request carries no session, when the
// session is dead (the row is the authority — a stale cookie is never
// re-planted), or when the row was renewed within the last day. Otherwise
// the row's expiry and the browser's cookie both jump to now + TTL.
pub fun refresh-session( req : request, resp : response ) : <db,time|e> response
  match resp.header("set-cookie")
    Just(_)  -> resp
    Nothing  ->
      val tok = session-token(req)
      if tok == "" then resp
      else
        val rows = query(
          "SELECT (datetime(expires_at) < datetime('now', '+' || ? || ' seconds')) " ++
          "FROM session WHERE token = ? AND datetime(expires_at) > datetime('now')",
          [num(renew-threshold-seconds()), txt(tok)]
        )
        match rows
          Cons(r, _) ->
            if int(r.col(0)) == 1 then
              val _ = exec("UPDATE session SET expires_at = ? WHERE token = ?",
                           [txt(session-expiry()), txt(tok)])
              // The row is renewed for everyone; only a cookie client is
              // handed the cookie again.
              if session-is-bearer(req) then resp
              else resp.with-header("Set-Cookie", session-cookie(req, tok))
            else resp
          Nil -> resp

// The session token a request carries: `Authorization: Bearer <token>`
// (the JSON API, scripts, agents) or the `session` cookie (the browser).
// Same table, same lifetime, same owner — a bearer token IS a session
// token, so revoking one revokes the other and nothing has two notions of
// "logged in".
pub fun session-token( req : request ) : string
  match req.header("authorization").default("").trim.starts-with("Bearer ")
    Just(rest) -> rest.string.trim
    Nothing    -> cookie-value(req.header("cookie").default(""), "session")

// True iff the request authenticated with a bearer header rather than a
// cookie — such a client manages its own token and gets no Set-Cookie.
pub fun session-is-bearer( req : request ) : bool
  req.header("authorization").default("").trim.starts-with("Bearer ").is-just

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
