// annexwyrm/web/multipart — RFC 7578 multipart/form-data parser.
//
// We assume the body fits in memory (Caddy caps it via `request_body
// max_size`). Streaming would require an effectful interpreter; for an
// archive tool that's a future optimisation.

module web/multipart

import core/types

// One form part. `name` is the form field name; `filename` is "" for
// non-file parts (and the body is then the field value as a UTF-8
// string).
pub value struct mpart
  name        : string
  filename    : string
  media-type  : string
  body        : string

// Parse a body whose Content-Type was
// `multipart/form-data; boundary=BOUNDARY`. Returns Nothing if the body
// doesn't start with the boundary or no parts could be parsed.
pub fun parse-multipart( content-type : string, body : string ) : div maybe<list<mpart>>
  match boundary-of(content-type)
    Nothing -> Nothing
    Just(b) ->
      // The real separator on the wire is "--<boundary>" (two leading
      // hyphens). The body starts with that.
      val sep = "--" ++ b
      val chunks = split-on(body, sep)
      // The first chunk is whatever was before the first separator
      // (per spec, it MUST be empty or a preamble we ignore). The last
      // chunk is the trailing `--` terminator marker. Both are dropped.
      val real-chunks = chunks.tail.init-of
      val parts = real-chunks.flatmap(parse-one-part)
      match parts
        Nil -> Nothing
        ps  -> Just(ps)

// Find a single field by name, returning its body as a string.
pub fun field( ps : list<mpart>, fname : string ) : maybe<string>
  match ps
    Nil -> Nothing
    Cons(p, rest) -> if p.name == fname then Just(p.body) else field(rest, fname)

// All file parts (Content-Disposition with a filename).
pub fun files( ps : list<mpart> ) : list<mpart>
  ps.filter(fn(p) p.filename != "")

// All instances of a repeated field (the "N remotes via [+]" pattern).
pub fun all-fields( ps : list<mpart>, fname : string ) : list<string>
  ps.flatmap(fn(p) if p.name == fname && p.filename == "" then [p.body] else [])

// ----------------------------------------------------------------------
//  Internals
// ----------------------------------------------------------------------

// Extract `boundary=…` from a Content-Type header.
fun boundary-of( ct : string ) : maybe<string>
  match media-type/parse(ct)
    Nothing -> Nothing
    Just(m) -> lookup-param(m.params, "boundary")

fun lookup-param( ps : list<(string,string)>, key : string ) : maybe<string>
  match ps
    Nil -> Nothing
    Cons((k,v), rest) -> if k == key then Just(v) else lookup-param(rest, key)

// Drop the last element of a list. (For "all but last" with an empty
// list this returns []; for one-element it also returns [].)
fun init-of( xs : list<a> ) : list<a>
  match xs
    Nil          -> []
    Cons(_, Nil) -> []
    Cons(x, ys)  -> Cons(x, init-of(ys))

// Split `s` on every occurrence of `sep`. The separator is consumed.
fun split-on( s : string, sep : string ) : div list<string>
  if sep == "" then [s]
  else split-on-go(s, sep, [])

fun split-on-go( s : string, sep : string, acc : list<string> ) : div list<string>
  match s.find(sep)
    Nothing -> (Cons(s, acc)).reverse
    Just(slc) ->
      val pre = slc.before.string
      val post = slc.after.string
      split-on-go(post, sep, Cons(pre, acc))

// Parse the chunk between two boundaries: first 2 bytes are CRLF, the
// rest is headers + blank line + body. The last 2 bytes are CRLF that
// precedes the next boundary — we strip them.
fun parse-one-part( chunk : string ) : list<mpart>
  // Strip the leading CRLF and trailing CRLF.
  val trimmed = trim-crlf(chunk)
  // Split headers from body at the first CRLFCRLF.
  match trimmed.find("\r\n\r\n")
    Nothing -> []   // malformed; drop silently
    Just(slc) ->
      val hdr-str = slc.before.string
      val body    = slc.after.string
      val hdrs    = parse-headers(hdr-str)
      val (name, filename) = parse-disposition(hdrs.lookup-i("content-disposition").default(""))
      val mtype = hdrs.lookup-i("content-type").default("")
      [Mpart(name, filename, mtype, body)]

fun trim-crlf( s : string ) : string
  s.strip-lead-crlf.strip-trail-crlf

fun strip-lead-crlf( s : string ) : string
  match s.starts-with("\r\n")
    Just(slc) -> slc.string
    Nothing   -> s

fun strip-trail-crlf( s : string ) : string
  match s.ends-with("\r\n")
    Just(slc) -> slc.string
    Nothing   -> s

fun parse-headers( s : string ) : list<(string,string)>
  s.split("\r\n").flatmap(parse-header-line)

fun parse-header-line( line : string ) : list<(string,string)>
  match line.find(":")
    Nothing -> []
    Just(slc) ->
      val k = slc.before.string.trim.to-lower
      val v = slc.after.string.trim
      [(k, v)]

fun lookup-i( hs : list<(string,string)>, key : string ) : maybe<string>
  match hs
    Nil -> Nothing
    Cons((k,v), rest) -> if k == key.to-lower then Just(v) else lookup-i(rest, key.to-lower)

// Content-Disposition: form-data; name="field"; filename="optional"
fun parse-disposition( s : string ) : (string,string)
  val parts = s.split(";").map(fn(p) p.trim)
  val name = parts.flatmap(fn(p) extract-kv(p, "name")).head.default("")
  val filename = parts.flatmap(fn(p) extract-kv(p, "filename")).head.default("")
  (name, filename)

fun extract-kv( p : string, key : string ) : list<string>
  match p.starts-with(key ++ "=")
    Nothing -> []
    Just(slc) ->
      val v = slc.string
      [strip-quotes(v)]

fun strip-quotes( s : string ) : string
  if s.starts-with("\"").bool && s.ends-with("\"").bool && s.count >= 2
    then s.list.tail.init.string
    else s
