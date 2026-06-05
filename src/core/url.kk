// annexwyrm/core/url — minimal absolute-URL parsing.
//
// We only need what HTTP Signatures and addressing demand: scheme, host,
// port, path, query, fragment. Pure; throws no exceptions.

module core/url

// A parsed absolute URL. Port = 0 means "default for the scheme".
pub value struct url-parts
  scheme   : string             // "https" or "http"
  host     : string             // "annexwyrm.example.com"
  port     : int                // 0 = default
  path     : string             // "/users/alice" (always begins with '/')
  query    : string             // "" or "key=val&..." (no leading '?')
  fragment : string             // "" or "main-key" (no leading '#')

// Default port for the scheme.
pub fun url-parts/default-port( u : url-parts ) : int
  if u.scheme == "https" then 443
  elif u.scheme == "http" then 80
  else 0

// True iff the URL is on the default port.
pub fun url-parts/is-default-port( u : url-parts ) : bool
  u.port == 0 || u.port == u.default-port

// The "authority" segment as it appears in a URL: host or host:port.
pub fun url-parts/authority( u : url-parts ) : string
  if u.is-default-port then u.host
  else u.host ++ ":" ++ u.port.show

// The "request-target" we sign per HTTP Signatures: path + "?query".
pub fun url-parts/request-target( u : url-parts ) : string
  if u.query == "" then u.path
  else u.path ++ "?" ++ u.query

// Re-serialise into a string. Round-trips a value previously parsed.
pub fun url-parts/show( u : url-parts ) : string
  val base = u.scheme ++ "://" ++ u.authority ++ u.path
  val withq = if u.query == "" then base else base ++ "?" ++ u.query
  if u.fragment == "" then withq else withq ++ "#" ++ u.fragment

// Parse an absolute URL. Returns Nothing on a relative or otherwise
// malformed input.
pub fun url-parse( s : string ) : maybe<url-parts>
  match s.split("://")
    Cons(scheme, Cons(rest, Nil)) ->
      val (auth-and-path, fragment) = split-once(rest, "#")
      val (auth-and-path2, query)   = split-once(auth-and-path, "?")
      val (authority, path)         = split-once-with-slash(auth-and-path2)
      val (host, port)              = parse-authority(authority)
      Just(Url-parts(scheme.to-lower, host.to-lower, port,
                     path, query, fragment))
    _ -> Nothing

// Split on the first occurrence of `sep`. If absent, second is "".
fun split-once( s : string, sep : string ) : (string,string)
  match s.find(sep)
    Nothing -> (s, "")
    Just(slc) -> (slc.before.string, slc.after.string)

// Split authority+path at the first "/", keeping the slash on the path.
// "host:8080/users/x" => ("host:8080", "/users/x")
// "host:8080"          => ("host:8080", "/")
fun split-once-with-slash( s : string ) : (string,string)
  match s.find("/")
    Nothing -> (s, "/")
    Just(slc) -> (slc.before.string, "/" ++ slc.after.string)

// Parse "host" or "host:port". Returns (host, 0) if no port.
fun parse-authority( s : string ) : (string,int)
  match s.split(":")
    Cons(h, Cons(p, Nil)) ->
      val n = p.parse-int.default(0)
      (h, n)
    _ -> (s, 0)

// Percent-encode a string for use as a URL path segment or query value.
// Encodes everything outside [A-Za-z0-9._~-].
pub fun url-encode( s : string ) : string
  s.list.map(fn(c) encode-char(c)).join("")

fun encode-char( c : char ) : string
  if c.is-alpha || c.is-digit || c == '-' || c == '_' || c == '.' || c == '~'
    then c.string
    else "%" ++ pad-byte(c.int)

fun pad-byte( n : int ) : string
  val hi = (n / 16) % 16
  val lo = n % 16
  hex-char(hi).string ++ hex-char(lo).string

fun hex-char( n : int ) : char
  if n < 10 then ('0'.int + n).char
  else ('A'.int + n - 10).char

// Decode a percent-encoded string. Best-effort; invalid escapes pass
// through unchanged.
pub fun url-decode( s : string ) : div string
  decode-chars(s.list, [])

fun decode-chars( cs : list<char>, acc : list<char> ) : div string
  match cs
    Nil -> acc.reverse.string
    Cons('%', Cons(a, Cons(b, rest))) ->
      match parse-hex-byte(a, b)
        Just(byte) -> decode-chars(rest, Cons(byte.char, acc))
        Nothing    -> decode-chars(Cons(a, Cons(b, rest)), Cons('%', acc))
    Cons('+', rest) -> decode-chars(rest, Cons(' ', acc))
    Cons(c, rest)   -> decode-chars(rest, Cons(c, acc))

fun parse-hex-byte( a : char, b : char ) : maybe<int>
  match (hex-val(a), hex-val(b))
    (Just(hi), Just(lo)) -> Just(hi * 16 + lo)
    _                    -> Nothing

fun hex-val( c : char ) : maybe<int>
  if c >= '0' && c <= '9' then Just(c.int - '0'.int)
  elif c >= 'a' && c <= 'f' then Just(c.int - 'a'.int + 10)
  elif c >= 'A' && c <= 'F' then Just(c.int - 'A'.int + 10)
  else Nothing

// Parse "key1=val1&key2=val2" form-encoded query string.
pub fun query-parse( s : string ) : div list<(string,string)>
  if s == "" then []
  else s.split("&").map(fn(pair) parse-pair(pair))

fun parse-pair( p : string ) : div (string,string)
  match p.split("=")
    Cons(k, Cons(v, _)) -> (url-decode(k), url-decode(v))
    Cons(k, Nil)        -> (url-decode(k), "")
    Nil                 -> ("", "")
