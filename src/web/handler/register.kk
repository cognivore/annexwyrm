// annexwyrm/web/handler/register — GET/POST /register?invite=<token>.
//
// The ONLY way to become a tenant. Registration is invite-gated: an admin
// mints a single-use token (see web/handler/invites); /register validates it
// and creates a new local actor (fresh RSA keypair + argon2id login), marks
// the invite consumed, and signs the new tenant straight in (session cookie)
// pointed at /settings so they configure their storage backend. There is no
// open sign-up — a missing/expired/used token is a flat 404.

module web/handler/register

import core/types
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/crypto
import ap/actor          // build-local-actor
import web/prefs
import web/server
import web/html/register

// GET /register?invite=<token>
pub fun handle-register-form( req : request ) : <db,config,div|e> response
  val token = invite-token(req.query)
  if !invite-open(token) then
    not-found("invalid or expired invite")
  else
    ok-html(render-register-form(token, "", get-page-width()))

// POST /register (token in the body, alongside the chosen credentials).
pub fun handle-register-post( req : request )
  : <db,time,rng,log,config,crypto,div|e> response
  val form = query-parse(req.body)
  val token = field-of(form, "invite")
  if !invite-open(token) then
    not-found("invalid or expired invite")
  else
    val raw-user = field-of(form, "username")
    val username = normalize-username(raw-user)
    val password = field-of(form, "password")
    val confirm  = field-of(form, "confirm")
    val display  = field-of(form, "name").trim
    if username == "" || username.count > 32 then
      reject(token, "username must be 1–32 chars of a–z, 0–9, '-' or '_'")
    elif reserved(username) then
      reject(token, "that username is reserved; pick another")
    elif username-taken(username) then
      reject(token, "that username is already taken")
    elif password.count < 8 then
      reject(token, "password must be at least 8 characters")
    elif password != confirm then
      reject(token, "passwords do not match")
    else
      create-tenant(req, token, username, password, display)

// Build the new tenant: keypair, actor row, login row, consume the invite,
// and open a session. Returns a 303 to /settings with the session cookie.
fun create-tenant( req : request, token : string, username : string,
                   password : string, display : string )
  : <db,time,rng,log,config,crypto,div|e> response
  val (priv, pubkey) = rsa-keygen()
  val a = build-local-actor(get-base-url(), username, display, "", pubkey)
  val now = now-iso()
  val _ = exec(
    "INSERT INTO actor (id, local, username, domain, name, summary, " ++
    "inbox, outbox, followers, following, shared_inbox, public_key_pem, " ++
    "private_key_pem, manually_approves, discoverable, is_admin, created_at) " ++
    "VALUES (?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)",
    [txt(a.id), txt(username), txt(get-domain()),
     txt(a.name), txt(a.summary),
     txt(a.inbox), txt(a.outbox), txt(a.followers), txt(a.following),
     txt(a.shared-inbox), txt(a.public-key-pem), txt(priv),
     num(0), num(1), txt(now)]
  )
  val _ = exec(
    "INSERT INTO local_login (actor_id, password_hash, created_at) VALUES (?,?,?)",
    [txt(a.id), txt(argon2id-hash(password)), txt(now)]
  )
  // Consume the invite (single-use): record who claimed it and when.
  val _ = exec(
    "UPDATE invite SET used_by = ?, used_at = ? WHERE token = ? AND used_by IS NULL",
    [txt(a.id), txt(now), txt(token)]
  )
  info("register/created", [("actor", a.id)])
  open-session(req, a.id, now)

// Mint a session for `actor-id` and return the cookie-bearing redirect.
fun open-session( req : request, actor-id : url, now : iso-time )
  : <db,time,rng,log,config,div|e> response
  val tok = rand-hex(32)
  val expiry = iso-from-unix(now-unix() + 60 * 60 * 24 * 14)  // 14d
  val _ = exec("DELETE FROM session WHERE actor_id = ?", [txt(actor-id)])
  val _ = exec(
    "INSERT INTO session (token, actor_id, created_at, expires_at) VALUES (?,?,?,?)",
    [txt(tok), txt(actor-id), txt(now), txt(expiry)]
  )
  see-other("/settings").with-header("Set-Cookie",
    "session=" ++ tok ++ "; Path=/; HttpOnly; SameSite=Strict; Max-Age=1209600"
    ++ secure-attr(req))

// ----------------------------------------------------------------------
//  Validation helpers
// ----------------------------------------------------------------------

pub fun invite-token( q : string ) : div string
  field-of(query-parse(q), "invite")

// True iff `token` names an open (unused, unexpired) invite.
fun invite-open( token : string ) : db bool
  if token == "" then False
  else
    val rows = query(
      "SELECT 1 FROM invite WHERE token = ? AND used_by IS NULL " ++
      "AND datetime(expires_at) > datetime('now')",
      [txt(token)]
    )
    match rows { Cons(_,_) -> True; _ -> False }

fun username-taken( username : string ) : db bool
  val rows = query(
    "SELECT 1 FROM actor WHERE local = 1 AND username = ?", [txt(username)]
  )
  match rows { Cons(_,_) -> True; _ -> False }

// Normalise to a URL/federation-safe handle: lowercase, keep only a–z, 0–9,
// '-' and '_'. Mirrors annex/item's tag normalisation so a username is always
// a clean single path segment under /users/<u> and a valid WebFinger handle.
fun normalize-username( s : string ) : string
  s.trim.to-lower.list.filter(fn(c)
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
  ).string

// Structural / confusable names we never let a tenant claim.
fun reserved( u : string ) : bool
  ["admin","root","inbox","outbox","followers","following","items","item",
   "upload","login","logout","settings","register","invites","invite",
   "search","tags","tag","static","users","user","nodeinfo","follow",
   "unfollow","activities","well-known","api","public"].any(fn(r) r == u)

fun reject( token : string, msg : string ) : <db,config|e> response
  ok-html(render-register-form(token, msg, get-page-width()))

fun field-of( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else field-of(rest, k)

// "; Secure" iff the request arrived over HTTPS (mirrors login's gate so the
// http:// dev path keeps working).
fun secure-attr( req : request ) : string
  if req.header("x-forwarded-proto").default("") == "https" then "; Secure" else ""
