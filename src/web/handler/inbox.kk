// annexwyrm/web/handler/inbox — POST /users/<u>/inbox and POST /inbox.
//
// 1. Parse JSON body
// 2. Verify HTTP Signature (fetching the sender's public key if needed)
// 3. Dispatch via `ap/inbox`
// 4. Return 202 (per fediverse convention; remote servers don't care
//    about the response body)

module web/handler/inbox

import core/types
import core/json
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/crypto
import effects/fetch
import ap/activity
import ap/inbox
import ap/sign
import ap/actor
import ap/actor_cache
import ap/persist   // local-actor-id-for
import web/server

pub fun handle-user-inbox( req : request, u : string )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  if local-actor-id-for(u) == "" then not-found("no such user")
  else dispatch-inbox(req)

pub fun handle-shared-inbox( req : request )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  dispatch-inbox(req)

fun dispatch-inbox( req : request )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  if req.method != "POST" then method-not-allowed("POST")
  else match json-parse(req.body)
    Nothing  -> bad-request("invalid JSON")
    Just(j)  -> dispatch-parsed(req, j)

fun dispatch-parsed( req : request, j : json )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  match ap-activity/from-json(j)
    Nothing   -> bad-request("not an Activity")
    Just(act) -> dispatch-act(req, j, act)

fun dispatch-act( req : request, body : json, act : ap-activity )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  val sig-ok = verify-signature(req, act)
  if sig-ok then handle-after-verify(body, act)
  else handle-unsigned(act)

fun handle-after-verify( body : json, act : ap-activity )
  : <db,time,rng,log,config,div|e> response
  match handle-inbox-activity(body, act)
    Nothing   -> accepted-empty()
    Just(err) -> bad-request(err)

// Per fediverse convention, accept unsigned Delete activities — the
// sending server has often already deleted its keypair by the time we
// receive the tombstone.
fun handle-unsigned( act : ap-activity ) : log response
  match act.kind
    AcDelete -> accepted-empty()
    _ ->
      warn("inbox/unsigned",
        [("from", act.actor), ("type", act.kind.show)])
      unauthorized("invalid HTTP signature")

// ----------------------------------------------------------------------
//  Signature verification
// ----------------------------------------------------------------------

fun verify-signature( req : request, act : ap-activity )
  : <db,time,fetch,log,crypto,div|e> bool
  match req.header("signature")
    Nothing -> False
    Just(sig-hdr) ->
      match parse-signature-header(sig-hdr)
        Nothing -> False
        Just(parsed) ->
          // The keyId is normally "<actor>#main-key"; strip the fragment.
          val actor-id = parsed.key-id.split("#").head.default("")
          // CRITICAL: bind the signing key to the activity's actor. The
          // signature only proves possession of the key behind `keyId`; it
          // says NOTHING about who `act.actor` claims to be. Without this
          // check any peer with any valid keypair signs as themselves while
          // putting actor="<victim>" in the body — full impersonation
          // (forged Create/Update/Delete/Follow/Undo as the local owner or
          // anyone else). Require the keyId's actor to BE the activity actor.
          if !same-actor(actor-id, act.actor) then
            warn("inbox/keyid-actor-mismatch",
              [("key-actor", actor-id), ("activity-actor", act.actor)])
            False
          // The activity id must share an origin with its actor. Otherwise a
          // peer (signing legitimately as itself) could submit an activity
          // whose id lives on ANOTHER server's domain, pre-seeding the
          // dedup table to suppress that server's real activity (id-based
          // dedup poisoning).
          elif !same-origin(act.id, act.actor) then
            warn("inbox/id-actor-origin-mismatch",
              [("id", act.id), ("actor", act.actor)])
            False
          // The signed-header set is attacker-chosen. A near-empty set (or
          // one omitting `digest`) means the body — the entire activity — is
          // unauthenticated even though the request "is signed". Require a
          // minimum set that covers the request line, host, date, and the
          // body digest (inbox is always POST-with-body).
          elif !covers-required(parsed.headers) then
            warn("inbox/insufficient-signed-headers",
              [("signed", parsed.headers.join(" "))])
            False
          // The signed Date must be recent. Without a freshness window a
          // captured signed POST replays forever; the window (±12h, generous
          // for clock skew) plus id-dedup bounds replay to a no-op.
          elif !date-fresh(req.header("date").default("")) then
            warn("inbox/stale-or-missing-date",
              [("date", req.header("date").default(""))])
            False
          else
            val attempt-first = try-with(actor-id, False, req, parsed)
            if attempt-first then True
            else
              // Try once more with a forced re-fetch in case the actor
              // rotated keys.
              try-with(actor-id, True, req, parsed)

// True iff two actor URLs denote the same actor (exact match modulo a
// single trailing slash). Empty never matches.
fun same-actor( a : url, b : url ) : bool
  a != "" && b != "" && norm-actor(a) == norm-actor(b)

fun norm-actor( s : string ) : string
  match s.ends-with("/")
    Just(slc) -> slc.string
    Nothing   -> s

// True iff two URLs share scheme + authority (host[:port]).
fun same-origin( a : url, b : url ) : bool
  match (url-parse(a), url-parse(b))
    (Just(ua), Just(ub)) -> ua.scheme == ub.scheme && ua.authority == ub.authority
    _ -> False

// Freshness window for a signed inbound Date header: ±12h (clock-skew
// tolerant; replay beyond this is rejected). Empty/unparseable ⇒ not fresh.
val date-skew-secs : int = 43200

fun date-fresh( http-date : string ) : <time|e> bool
  if http-date == "" then False
  else
    val t = parse-http-date(http-date)
    if t < 0 then False
    else
      val delta = now-unix() - t
      (if delta < 0 then 0 - delta else delta) <= date-skew-secs

// The minimum signed-header set for an inbound POST: the request line, the
// host, a date, and the body digest. All four must be present (the digest
// itself is then matched against the body in verify-inbound).
val required-signed-headers : list<string>
  = ["(request-target)", "host", "date", "digest"]

fun covers-required( signed : list<string> ) : bool
  val low = signed.map(fn(h) h.to-lower)
  required-signed-headers.all(fn(r) low.any(fn(h) h == r))

fun try-with( actor-id : url, refresh : bool, req : request, parsed : parsed-sig )
  : <db,time,fetch,log,crypto,div|e> bool
  match resolve-actor(actor-id, refresh)
    Nothing -> False
    Just(rec) ->
      if rec.public-key-pem == "" then False
      else
        val path-with-query = if req.query == ""
          then req.path
          else req.path ++ "?" ++ req.query
        val hdr = fn(name : string) req.header(name).default("")
        verify-inbound("post", path-with-query, req.body,
                       hdr, rec.public-key-pem, parsed)
