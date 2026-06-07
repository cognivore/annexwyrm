// annexwyrm/web/handler/login — GET/POST /login and POST /logout.
//
// Uses argon2id for password storage and a 256-bit random session token
// stored in the `session` table and as a `Set-Cookie: session=…` cookie.

module web/handler/login

import core/types
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/crypto
import web/prefs
import web/server
import web/html/login
import web/multipart

pub fun handle-login-form( req : request ) : <db,config|e> response
  ok-html(render-login-form("", get-page-width()))

pub fun handle-login-post( req : request )
  : <db,time,rng,log,config,crypto,div|e> response
  val form = form-decode(req.body)
  val username = form-get(form, "username")
  val password = form-get(form, "password")
  if username == "" || password == "" then
    ok-html(render-login-form("missing fields", get-page-width()))
  else
    val rows = query(
      "SELECT a.id, l.password_hash FROM actor a " ++
      "JOIN local_login l ON l.actor_id = a.id " ++
      "WHERE a.local = 1 AND a.username = ?",
      [txt(username)]
    )
    match rows
      Nil -> ok-html(render-login-form("invalid credentials", get-page-width()))
      Cons(r, _) ->
        val aid = text(r.col(0))
        val phc = text(r.col(1))
        if !argon2id-verify(phc, password) then
          ok-html(render-login-form("invalid credentials", get-page-width()))
        else
          val tok = rand-hex(32)
          val now = now-iso()
          val expiry = iso-from-unix(now-unix() + 60 * 60 * 24 * 14) // 14d
          // Rotate: drop any prior sessions for this actor before minting a
          // new one, so a fresh login invalidates older tokens (a stolen or
          // stale cookie does not outlive the next login).
          val _ = exec("DELETE FROM session WHERE actor_id = ?", [txt(aid)])
          exec(
            "INSERT INTO session (token, actor_id, created_at, expires_at) " ++
            "VALUES (?,?,?,?)",
            [txt(tok), txt(aid), txt(now), txt(expiry)]
          )
          val resp = see-other("/")
          // SameSite=Strict (not Lax): the session cookie authorises only
          // owner mutations (upload/edit/publish/follow/logout); it never
          // needs to ride a cross-site request. Strict means no browser
          // attaches it to ANY cross-origin request, closing the CSRF gap
          // that Lax leaves open for cross-site POSTs. HttpOnly keeps it
          // out of JS; Secure (HTTPS only) is added on the public site.
          resp.with-header("Set-Cookie",
            "session=" ++ tok ++ "; Path=/; HttpOnly; SameSite=Strict; Max-Age=1209600"
            ++ secure-attr(req))

pub fun handle-logout( req : request )
  : <db,log,config,div|e> response
  val tok = cookie-value(req.header("cookie").default(""), "session")
  if tok != "" then
    val _ = exec("DELETE FROM session WHERE token = ?", [txt(tok)])
    ()
  val resp = see-other("/")
  resp.with-header("Set-Cookie",
    "session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" ++ secure-attr(req))

// ----------------------------------------------------------------------
//  Form-encoded body parsing (application/x-www-form-urlencoded)
// ----------------------------------------------------------------------

fun form-decode( body : string ) : div list<(string,string)>
  query-parse(body)

fun form-get( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else form-get(rest, k)

// "; Secure" iff this request arrived over HTTPS. Caddy in front of the
// daemon sets X-Forwarded-Proto; the tuntun-fronted public site pins it to
// `https`, the local http:// dev site to `http`. Secure means "send only
// over HTTPS", so adding it unconditionally would silently break login on
// the http://annexwyrm.localhost dev path (the browser would drop the
// cookie) — exactly the trap the previous CTO hit. Gate it on the scheme.
fun secure-attr( req : request ) : string
  if req.header("x-forwarded-proto").default("") == "https"
    then "; Secure" else ""

fun cookie-value( header-val : string, name : string ) : string
  header-val.split(";").map(fn(s) s.trim).flatmap(fn(p)
    match p.starts-with(name ++ "=")
      Just(slc) -> [slc.string]
      Nothing   -> []
  ).head.default("")

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }
