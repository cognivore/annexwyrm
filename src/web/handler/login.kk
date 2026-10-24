// annexwyrm/web/handler/login — GET/POST /login and POST /logout.
//
// Uses argon2id for password storage and a 256-bit random session token
// stored in the `session` table and as a `Set-Cookie: session=…` cookie.
// How long both live, and the cookie's attributes, are web/session's
// business (`session-expiry`, `session-cookie`) — not decided here.

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
import web/session
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
    match verify-login(username, password)
      Nothing -> ok-html(render-login-form("invalid credentials", get-page-width()))
      Just(aid) ->
        // Rotate: a browser login drops this actor's prior sessions, so a
        // stolen or stale cookie does not outlive the next login. (That
        // includes API tokens — mint them again after a browser login.)
        val (tok, _) = mint-session(aid, True)
        see-other("/").with-header("Set-Cookie", session-cookie(req, tok))

// The one password check: the local actor id for a username/password
// pair, or Nothing. Shared by the form and the JSON API so there is a
// single place credentials are judged.
pub fun verify-login( username : string, password : string )
  : <db,crypto|e> maybe<string>
  if username == "" || password == "" then Nothing
  else
    val rows = query(
      "SELECT a.id, l.password_hash FROM actor a " ++
      "JOIN local_login l ON l.actor_id = a.id " ++
      "WHERE a.local = 1 AND a.username = ?",
      [txt(username)]
    )
    match rows
      Nil -> Nothing
      Cons(r, _) ->
        if argon2id-verify(text(r.col(1)), password) then Just(text(r.col(0)))
        else Nothing

// Mint a session row for `aid`; returns (token, expires_at). `rotate`
// first deletes the actor's other sessions (the browser login's
// invalidation story); the API login keeps them, so a script's token
// does not log the browser out.
pub fun mint-session( aid : string, rotate : bool ) : <db,time,rng|e> (string, iso-time)
  val tok = rand-hex(32)
  val now = now-iso()
  val expiry = session-expiry()
  if rotate then
    val _ = exec("DELETE FROM session WHERE actor_id = ?", [txt(aid)])
    ()
  val _ = exec(
    "INSERT INTO session (token, actor_id, created_at, expires_at) " ++
    "VALUES (?,?,?,?)",
    [txt(tok), txt(aid), txt(now), txt(expiry)]
  )
  (tok, expiry)

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

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }
