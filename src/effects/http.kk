// annexwyrm/effects/http — request/response shape.
//
// This module is *just types*; the effects that actually do HTTP I/O
// (`fetch`, `deliver`) live next door. Putting the shape here keeps
// `fetch` and `deliver` from depending on each other.

module effects/http

// One HTTP header. Names are lowercased on receipt (HTTP header field
// names are case-insensitive) so equality compares cleanly.
pub alias header = (string,string)

// An outbound or inbound HTTP request. Body is the raw payload bytes
// (packed in a Koka string); pass an empty string when there's nothing
// to send.
pub value struct http-request
  method  : string                    // "GET", "POST"
  url     : string                    // full URL for outbound; path for inbound
  headers : list<header>
  body    : string

// An HTTP response.  `status` is the numeric code.
pub value struct http-response
  status  : int
  headers : list<header>
  body    : string

// True iff `status` is in the 2xx success range.
pub fun http-response/ok( r : http-response ) : bool
  r.status >= 200 && r.status < 300

// Look up a header value, case-insensitively.
pub fun http-response/header( r : http-response, name : string ) : maybe<string>
  find-header(r.headers, name.to-lower)

pub fun http-request/header( r : http-request, name : string ) : maybe<string>
  find-header(r.headers, name.to-lower)

fun find-header( hs : list<header>, name : string ) : maybe<string>
  match hs
    Nil -> Nothing
    Cons((k,v), rest) ->
      if k.to-lower == name then Just(v)
      else find-header(rest, name)
