// annexwyrm/web/handler/follow — POST /follow and /unfollow.
//
// Form fields:
//   target=<acct or actor URL>

module web/handler/follow

import core/types
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/fetch
import effects/crypto
import ap/outbox
import ap/actor_cache
import ap/webfinger
import web/server
import web/handler/item   // for is-owner-session, cookie helpers

pub fun handle-follow-action( req : request )
  : <db,time,rng,log,config,fetch,crypto,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val form = query-parse(req.body)
    val target = form-get(form, "target")
    val target-url = resolve-target(target)
    if target-url == "" then bad-request("could not resolve target actor")
    else
      // Make sure the target's row exists; we need their inbox to deliver to.
      val _ = resolve-actor(target-url, False)
      emit-follow(target-url)
      see-other("/")

pub fun handle-unfollow-action( req : request )
  : <db,time,rng,log,config,crypto,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val form = query-parse(req.body)
    val target = form-get(form, "target")
    val target-url = resolve-target(target)
    if target-url == "" then bad-request("could not resolve target actor")
    else
      val _ = emit-undo-follow(target-url)
      see-other("/")

// Accept either a plain actor URL ("https://example.com/users/x") or an
// `acct:`-style shorthand ("user@example.com"). For the latter we'd
// need a WebFinger round-trip; here we do the simpler `https://` form.
fun resolve-target( s : string ) : url
  if s.starts-with("https://").bool || s.starts-with("http://").bool then s
  else
    // user@host → https://host/users/user  (a hopeful guess; WebFinger
    // is the right tool but adds another round-trip).
    match s.split("@")
      Cons(u, Cons(h, Nil)) -> "https://" ++ h ++ "/users/" ++ u
      _ -> ""

fun form-get( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else form-get(rest, k)
