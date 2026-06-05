// annexwyrm/web/server — request/response types.
//
// Pure data; the loop that pulls bytes off the Unix socket lives in
// `interp/socket_server`. Handlers consume `request` and produce
// `response`.

module web/server

// One inbound HTTP request from Caddy. Headers come in case-insensitive
// per HTTP; we normalise names to lowercase before they hit handlers,
// so `req.header("content-type")` always finds them.
pub value struct request
  method  : string                    // "GET", "POST", …
  path    : string                    // "/users/alice/inbox"
  query   : string                    // "page=2" (no leading "?")
  headers : list<(string,string)>
  body    : string                    // raw bytes
  remote  : string                    // "X-Forwarded-For" or socket peer

pub value struct response
  status      : int
  status-text : string
  headers     : list<(string,string)>
  body        : string

// Status-line constructors.
pub fun ok-text( body : string ) : response
  Response(200, "OK",
           [("Content-Type", "text/plain; charset=utf-8")],
           body)

pub fun ok-html( body : string ) : response
  Response(200, "OK",
           [("Content-Type", "text/html; charset=utf-8")],
           body)

pub fun ok-jsonld( body : string ) : response
  Response(200, "OK",
           [("Content-Type", "application/activity+json; charset=utf-8"),
            ("Vary", "Accept")],
           body)

pub fun ok-jrd( body : string ) : response
  Response(200, "OK",
           [("Content-Type", "application/jrd+json; charset=utf-8")],
           body)

pub fun ok-json( body : string ) : response
  Response(200, "OK",
           [("Content-Type", "application/json; charset=utf-8")],
           body)

pub fun see-other( location : string ) : response
  Response(303, "See Other",
           [("Location", location),
            ("Content-Type", "text/plain")],
           "redirecting to " ++ location ++ "\n")

pub fun bad-request( msg : string ) : response
  Response(400, "Bad Request",
           [("Content-Type", "text/plain; charset=utf-8")],
           msg ++ "\n")

pub fun unauthorized( msg : string ) : response
  Response(401, "Unauthorized",
           [("Content-Type", "text/plain; charset=utf-8")],
           msg ++ "\n")

pub fun forbidden( msg : string ) : response
  Response(403, "Forbidden",
           [("Content-Type", "text/plain; charset=utf-8")],
           msg ++ "\n")

pub fun not-found( msg : string = "not found" ) : response
  Response(404, "Not Found",
           [("Content-Type", "text/plain; charset=utf-8")],
           msg ++ "\n")

pub fun gone( body : string = "gone" ) : response
  Response(410, "Gone",
           [("Content-Type", "text/plain; charset=utf-8")],
           body ++ "\n")

pub fun method-not-allowed( allow : string = "GET" ) : response
  Response(405, "Method Not Allowed",
           [("Allow", allow),
            ("Content-Type", "text/plain")],
           "method not allowed\n")

pub fun server-error( msg : string = "internal error" ) : response
  Response(500, "Internal Server Error",
           [("Content-Type", "text/plain; charset=utf-8")],
           msg ++ "\n")

pub fun accepted-empty() : response
  Response(202, "Accepted",
           [("Content-Type", "text/plain; charset=utf-8")],
           "")

// Header lookup, case-insensitive.
pub fun request/header( r : request, name : string ) : maybe<string>
  find-h(r.headers, name.to-lower)

pub fun response/header( r : response, name : string ) : maybe<string>
  find-h(r.headers, name.to-lower)

fun find-h( hs : list<(string,string)>, name : string ) : maybe<string>
  match hs
    Nil -> Nothing
    Cons((k,v), rest) ->
      if k.to-lower == name then Just(v)
      else find-h(rest, name)

// Add a header. Replaces existing headers with the same (case-insensitive) name.
pub fun with-header( r : response, name : string, value : string ) : response
  val cleaned = r.headers.filter(fn(h) h.fst.to-lower != name.to-lower)
  Response(r.status, r.status-text,
           cleaned ++ [(name, value)],
           r.body)

// Convenience: True iff the request's Accept header prefers JSON-LD /
// activity+json over HTML.
pub fun prefers-jsonld( r : request ) : bool
  val a = r.header("accept").default("")
  a.contains("application/activity+json") ||
  a.contains("application/ld+json")
