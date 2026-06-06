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
//
// CRITICAL: this is done in TWO phases because a `%XX` escape names a
// single BYTE, not a codepoint. A browser url-encodes the UTF-8 title
// "Café" as `Caf%C3%A9` — the two bytes 0xC3 0xA9 ARE the single
// codepoint 'é'. Decoding byte-by-byte into Koka chars (codepoints) and
// re-serialising would yield the two Latin-1 codepoints "Ã©" (mojibake),
// corrupting every accented / CJK / emoji character. So phase 1 resolves
// escapes + '+' into a flat byte list, and phase 2 re-interprets that
// byte list as UTF-8. (This matters most for the edit form, the first
// path to round-trip rich user text through query-parse; uploads use
// multipart, which carries the body's UTF-8 bytes verbatim.)
pub fun url-decode( s : string ) : div string
  utf8-assemble(collect-bytes(s.list, [])).string

// Phase 1 — resolve %XX escapes and '+' into a flat byte list. A literal
// char contributes its codepoint, which equals its byte for ASCII (all a
// conformant form-urlencoded body contains); a raw multibyte literal
// falls through utf8-assemble's else branch unchanged. Invalid `%`
// escapes pass through as the literal '%'.
fun collect-bytes( cs : list<char>, acc : list<int> ) : div list<int>
  match cs
    Nil -> acc.reverse
    Cons('%', Cons(a, Cons(b, rest))) ->
      match parse-hex-byte(a, b)
        Just(byte) -> collect-bytes(rest, Cons(byte, acc))
        Nothing    -> collect-bytes(Cons(a, Cons(b, rest)), Cons('%'.int, acc))
    Cons('+', rest) -> collect-bytes(rest, Cons(' '.int, acc))
    Cons(c, rest)   -> collect-bytes(rest, Cons(c.int, acc))

// Phase 2 — interpret the byte list as UTF-8, producing codepoints. A
// well-formed 2/3/4-byte sequence collapses to its single codepoint; any
// invalid unit (stray continuation, truncated sequence, or a raw
// codepoint >= 0x80 that isn't a UTF-8 lead) falls back to a direct
// codepoint, preserving the old best-effort behaviour for non-UTF-8 input.
fun utf8-assemble( bs : list<int> ) : div list<char>
  utf8-go(bs, [])

fun utf8-go( bs : list<int>, acc : list<char> ) : div list<char>
  match bs
    Nil -> acc.reverse
    Cons(b0, rest) ->
      if b0 < 0x80 then
        utf8-go(rest, Cons(b0.char, acc))
      elif b0 >= 0xc0 && b0 < 0xe0 then
        match rest
          Cons(b1, r2) ->
            if is-cont(b1)
              then utf8-go(r2, Cons((((b0 - 0xc0) * 0x40) + (b1 - 0x80)).char, acc))
              else utf8-go(rest, Cons(b0.char, acc))
          Nil -> utf8-go([], Cons(b0.char, acc))
      elif b0 >= 0xe0 && b0 < 0xf0 then
        match rest
          Cons(b1, Cons(b2, r3)) ->
            if is-cont(b1) && is-cont(b2)
              then utf8-go(r3, Cons(
                (((b0 - 0xe0) * 0x1000) + ((b1 - 0x80) * 0x40) + (b2 - 0x80)).char, acc))
              else utf8-go(rest, Cons(b0.char, acc))
          _ -> utf8-go(rest, Cons(b0.char, acc))
      elif b0 >= 0xf0 && b0 < 0xf8 then
        match rest
          Cons(b1, Cons(b2, Cons(b3, r4))) ->
            if is-cont(b1) && is-cont(b2) && is-cont(b3)
              then utf8-go(r4, Cons(
                (((b0 - 0xf0) * 0x40000) + ((b1 - 0x80) * 0x1000) +
                 ((b2 - 0x80) * 0x40) + (b3 - 0x80)).char, acc))
              else utf8-go(rest, Cons(b0.char, acc))
          _ -> utf8-go(rest, Cons(b0.char, acc))
      else
        utf8-go(rest, Cons(b0.char, acc))

fun is-cont( b : int ) : bool
  b >= 0x80 && b < 0xc0

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

// Split each pair on the FIRST '=' only. `split("=")` would discard
// everything after a second '=', truncating values that legitimately
// contain one — most notably a `review of` URL carrying a query string
// (https://host/items/x?ref=y). find + before/after keeps the value whole.
fun parse-pair( p : string ) : div (string,string)
  match p.find("=")
    Nothing   -> (url-decode(p), "")
    Just(slc) -> (url-decode(slc.before.string), url-decode(slc.after.string))
