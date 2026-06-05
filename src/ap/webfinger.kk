// annexwyrm/ap/webfinger — acct: → actor lookup.
//
// Pure: takes a username/domain and the local actor record, returns
// the JRD (JSON Resource Descriptor) per RFC 7033. The view layer
// hands the rendered JSON to the client with content-type
// `application/jrd+json`.

module ap/webfinger

import core/types
import core/json

pub value struct webfinger-q
  username : string
  domain   : string

// Parse an `acct:user@host` resource string. Returns Nothing if it
// doesn't start with `acct:` or doesn't contain a `@`.
pub fun parse-acct( resource : string ) : maybe<webfinger-q>
  match resource.starts-with("acct:")
    Nothing -> Nothing
    Just(slc) ->
      val rest = slc.string
      match rest.split("@")
        Cons(u, Cons(h, Nil)) -> Just(Webfinger-q(u, h))
        _ -> Nothing

// Build the JRD response for the queried subject. `actor-id` is the
// local actor's HTTPS URL.
pub fun build-jrd( subject : string, actor-id : url ) : json
  obj([
    ("subject", string/json(subject)),
    ("aliases", arr([string/json(actor-id)])),
    ("links",   arr([
      obj([
        ("rel",  string/json("self")),
        ("type", string/json("application/activity+json")),
        ("href", string/json(actor-id))
      ]),
      obj([
        ("rel",  string/json("http://webfinger.net/rel/profile-page")),
        ("type", string/json("text/html")),
        ("href", string/json(actor-id))
      ])
    ]))
  ])
