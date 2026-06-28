// annexwyrm/web/handler/webfinger — /.well-known/webfinger
//
// Maps `acct:user@domain` to the local actor URL.

module web/handler/webfinger

import core/types
import core/json
import core/url
import effects/db
import effects/config
import ap/webfinger
import ap/persist   // local-actor-id-for
import web/server

pub fun handle-webfinger( req : request ) : <db,config,div|e> response
  val resource = query-parse(req.query)
                   .filter(fn(p) p.fst == "resource")
                   .head.map(fn(p) p.snd).default("")
  if resource == "" then bad-request("missing resource= parameter")
  else
    match parse-acct(resource)
      Nothing -> bad-request("resource is not an acct: URI")
      Just(q) ->
        // Accept queries for our domain and any LOCAL tenant on it.
        if q.domain != get-domain() then
          not-found("no such account: " ++ resource)
        else
          val actor-id = local-actor-id-for(q.username)
          if actor-id == "" then not-found("no such account: " ++ resource)
          else ok-jrd(json/show(build-jrd(resource, actor-id)))
