// annexwyrm/web/handler/webfinger — /.well-known/webfinger
//
// Maps `acct:user@domain` to the local actor URL.

module web/handler/webfinger

import core/types
import core/json
import core/url
import effects/config
import ap/webfinger
import web/server

pub fun handle-webfinger( req : request ) : <config,div|e> response
  val resource = query-parse(req.query)
                   .filter(fn(p) p.fst == "resource")
                   .head.map(fn(p) p.snd).default("")
  if resource == "" then bad-request("missing resource= parameter")
  else
    match parse-acct(resource)
      Nothing -> bad-request("resource is not an acct: URI")
      Just(q) ->
        // Accept queries for our domain only.
        if q.domain != get-domain() then
          not-found("no such account: " ++ resource)
        elif q.username != get-local-username() then
          not-found("no such account: " ++ resource)
        else
          val actor-id = get-base-url() ++ "/users/" ++ q.username
          val jrd = build-jrd(resource, actor-id)
          ok-jrd(json/show(jrd))
