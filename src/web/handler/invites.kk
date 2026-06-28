// annexwyrm/web/handler/invites — GET/POST /invites (admin only).
//
// The admin mints single-use invite tokens here; /register consumes them.
// Gated to is-admin-session: a non-admin tenant (or anonymous) gets 403.

module web/handler/invites

import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import web/prefs
import web/session   // is-admin-session, session-actor
import web/server
import web/html/invites

pub fun handle-invites-form( req : request ) : <db,config,div|e> response
  if !is-admin-session(req) then forbidden("admins only")
  else
    val opens = query(
      "SELECT token, COALESCE(note,''), expires_at FROM invite " ++
      "WHERE used_by IS NULL AND datetime(expires_at) > datetime('now') " ++
      "ORDER BY created_at DESC",
      []
    ).map(fn(r) (text(r.col(0)), text(r.col(1)), text(r.col(2))))
    val used = query(
      "SELECT token, COALESCE(note,''), COALESCE(used_by,'') FROM invite " ++
      "WHERE used_by IS NOT NULL ORDER BY used_at DESC LIMIT 50",
      []
    ).map(fn(r) (text(r.col(0)), text(r.col(1)), text(r.col(2))))
    ok-html(render-invites(get-base-url(), opens, used, get-page-width()))

pub fun handle-invites-post( req : request ) : <db,time,rng,log,config,div|e> response
  if !is-admin-session(req) then forbidden("admins only")
  else
    val note = field-of(query-parse(req.body), "note").trim
    val token = rand-hex(32)
    val now = now-iso()
    val expiry = iso-from-unix(now-unix() + 60 * 60 * 24 * 14)  // 14d
    val owner = session-actor(req)
    val _ = exec(
      "INSERT INTO invite (token, created_by, note, created_at, expires_at) " ++
      "VALUES (?,?,?,?,?)",
      [txt(token), txt(owner), txt(note), txt(now), txt(expiry)]
    )
    info("invite/minted", [("by", owner)])
    see-other("/invites")

fun field-of( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else field-of(rest, k)

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }
