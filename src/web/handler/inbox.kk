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
import web/server

pub fun handle-user-inbox( req : request, u : string )
  : <db,time,rng,log,config,crypto,fetch,div|e> response
  if u != get-local-username() then not-found("no such user")
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
          val attempt-first = try-with(actor-id, False, req, parsed)
          if attempt-first then True
          else
            // Try once more with a forced re-fetch in case the actor
            // rotated keys.
            try-with(actor-id, True, req, parsed)

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
