// annexwyrm/ap/sign — HTTP Signatures (draft-cavage RSA-SHA256).
//
// Half of this module is *pure* canonicalisation — building the string
// to sign, parsing the `Signature` header, reconstructing what to verify.
// The other half wraps it with the `crypto` effect.

module ap/sign

import core/types
import core/url
import effects/crypto
import effects/http

// ----------------------------------------------------------------------
//  Parsed `Signature: …` header
// ----------------------------------------------------------------------

pub value struct parsed-sig
  key-id    : url
  algorithm : string                     // "rsa-sha256"
  headers   : list<string>               // order of names signed
  signature : string                     // base64

// Parse a `Signature: keyId="…", headers="…", signature="…"` value.
// Returns Nothing if any required field is missing.
pub fun parse-signature-header( hdr : string ) : maybe<parsed-sig>
  val fields = split-fields(hdr)
  val key-id = lookup(fields, "keyId").default("")
  val alg    = lookup(fields, "algorithm").default("rsa-sha256")
  val hdrs   = lookup(fields, "headers").default("(request-target) host date")
  val sig    = lookup(fields, "signature").default("")
  if key-id == "" || sig == "" then Nothing
  else Just(Parsed-sig(key-id, alg, hdrs.split(" "), sig))

// Split the `k1="v1", k2="v2"` header value into a (k,v) assoc list.
// We accept the quoted-string form only — every fediverse impl emits it.
fun split-fields( s : string ) : list<(string,string)>
  // We split on commas not inside quotes by walking the string.
  split-fields-go(s.list, [], [], False, [])

fun split-fields-go( cs : list<char>,
                     cur-key  : list<char>,
                     cur-val  : list<char>,
                     in-val   : bool,
                     acc      : list<(string,string)> ) : list<(string,string)>
  match cs
    Nil ->
      if cur-key.is-empty && cur-val.is-empty then acc.reverse
      else Cons((cur-key.reverse.string.trim, strip-quotes(cur-val.reverse.string)), acc).reverse
    Cons(',', rest) ->
      val k = cur-key.reverse.string.trim
      val v = strip-quotes(cur-val.reverse.string)
      split-fields-go(rest, [], [], False, Cons((k,v), acc))
    Cons('=', rest) ->
      if in-val
        then split-fields-go(rest, cur-key, Cons('=', cur-val), True, acc)
        else split-fields-go(rest, cur-key, [], True, acc)
    Cons(c, rest) ->
      if in-val
        then split-fields-go(rest, cur-key, Cons(c, cur-val), True, acc)
        else split-fields-go(rest, Cons(c, cur-key), cur-val, False, acc)

fun strip-quotes( s : string ) : string
  val t = s.trim
  if t.starts-with("\"").bool && t.ends-with("\"").bool && t.count >= 2
    then t.list.tail.init.string
    else t

fun lookup( fs : list<(string,string)>, key : string ) : maybe<string>
  match fs
    Nil -> Nothing
    Cons((k,v), rest) -> if k.to-lower == key.to-lower then Just(v) else lookup(rest, key)

// ----------------------------------------------------------------------
//  Building a Signature header
// ----------------------------------------------------------------------

// Build the `Signature: …` header value.
pub fun build-signature-header( key-id : url, headers : list<string>, sig-b64 : string ) : string
  "keyId=\"" ++ key-id ++ "\"," ++
  "algorithm=\"rsa-sha256\"," ++
  "headers=\"" ++ headers.join(" ") ++ "\"," ++
  "signature=\"" ++ sig-b64 ++ "\""

// Build the canonical string to sign / verify.  Each line is
// `name: value`; the special name `(request-target)` is replaced by
// `method path`.
//
// Per draft-cavage, lines are joined with LF (`\n`) and there is NO
// trailing newline.
pub fun canonical-string(
    method  : string,         // "post" / "get"
    target  : string,         // path + optional ?query
    headers : list<string>,   // names in signing order
    lookup  : (string) -> string
  ) : string
  headers.map(fn(h) header-line(h, method, target, lookup)).join("\n")

fun header-line( name : string, method : string, target : string,
                 lookup : (string) -> string ) : string
  if name == "(request-target)"
    then "(request-target): " ++ method.to-lower ++ " " ++ target
  else
    name.to-lower ++ ": " ++ lookup(name)

// ----------------------------------------------------------------------
//  Effect-using helpers
// ----------------------------------------------------------------------

// The headers we sign on every outbound POST. Order matters.
pub val sign-headers-post : list<string>
  = ["(request-target)", "host", "date", "digest"]

// The headers we sign on every outbound GET.
pub val sign-headers-get : list<string>
  = ["(request-target)", "host", "date"]

// Sign and return the fully-prepared `Signature` header value, plus
// the `Digest` (for POSTs) and `Date` (RFC 7231).
pub fun sign-outbound(
    method     : string,           // "post" / "get"
    target-url : url,               // full URL
    body       : string,            // "" for GET
    date-http  : string,            // RFC 7231 date string
    priv-key   : string,            // PEM
    key-id     : url
  ) : crypto (string, string, string)   // (signature-hdr, digest-hdr, date-hdr)
  match url-parse(target-url)
    Nothing -> ("", "", date-http)
    Just(u) ->
      val digest = if method.to-lower == "post" then http-digest(body) else ""
      val headers = if digest == "" then sign-headers-get else sign-headers-post
      val lookup-h = fn(n : string)
        if n.to-lower == "host"   then u.authority
        elif n.to-lower == "date" then date-http
        elif n.to-lower == "digest" then digest
        else ""
      val msg = canonical-string(method, u.request-target, headers, lookup-h)
      val sig-bytes = rsa-sign-sha256(priv-key, msg)
      val sig-b64   = b64-encode(sig-bytes)
      val hdr       = build-signature-header(key-id, headers, sig-b64)
      (hdr, digest, date-http)

// Verify an inbound request against the actor's public key. `header`
// looks up a header by name (case-insensitive); `path` is the URL path
// (with `?query` if signed). `body` is the raw request body (already
// read; used for digest verification).
pub fun verify-inbound(
    method  : string,
    path    : string,
    body    : string,
    header  : (string) -> string,
    pub-pem : string,
    parsed  : parsed-sig
  ) : crypto bool
  val msg = canonical-string(method, path, parsed.headers, header)
  match b64-decode(parsed.signature)
    Nothing -> False
    Just(sig-bytes) ->
      val sig-ok = rsa-verify-sha256(pub-pem, msg, sig-bytes)
      val digest-ok = if parsed.headers.any(fn(h) h.to-lower == "digest")
        then header("digest") == http-digest(body)
        else True
      sig-ok && digest-ok
