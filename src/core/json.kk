// annexwyrm/core/json — JSON value type plus parser and printer.
//
// Koka's standard library has no JSON, so we ship a small recursive
// descent parser on top of `std/text/parse`. JSON numbers are stored as
// their raw textual form (`JNumber("1234")`), avoiding any commitment to
// integer vs. float precision; converters in this module turn them into
// `int` on demand. ActivityPub does not use floats anywhere we care.

module core/json

import std/text/parse

// ----------------------------------------------------------------------
//  Value type
// ----------------------------------------------------------------------

pub type json
  JNull
  JBool( b : bool )
  JNumber( numstr : string )                       // textual; convert lazily
  JString( s : string )
  JArray( xs : list<json> )
  JObject( fields : list<(string,json)> )

// ----------------------------------------------------------------------
//  Smart constructors
// ----------------------------------------------------------------------

pub fun int/json( i : int ) : json
  JNumber(i.show)

pub fun bool/json( b : bool ) : json
  JBool(b)

pub fun string/json( s : string ) : json
  JString(s)

// Build an object from `(key, json)` pairs. Order is preserved; fediverse
// servers rely on `@context` being first, then `id`, `type`, etc.
pub fun obj( fields : list<(string,json)> ) : json
  JObject(fields)

pub fun arr( xs : list<json> ) : json
  JArray(xs)

// Sentinel for "field is absent from output". Used with `obj-opt`.
pub val jundefined : json = JNull   // sentinel; never appears in encoded output

// Like `obj` but drops fields whose value is `JNull` (a.k.a. jundefined).
// This is how we keep optional AP fields out of the wire format.
pub fun obj-opt( fields : list<(string,json)> ) : json
  JObject(fields.filter(fn(p) match p.snd { JNull -> False; _ -> True }))

// ----------------------------------------------------------------------
//  Accessors
// ----------------------------------------------------------------------

pub fun json/string( j : json ) : maybe<string>
  match j
    JString(s) -> Just(s)
    _          -> Nothing

pub fun json/int( j : json ) : maybe<int>
  match j
    JNumber(r) ->
      val whole = r.split(".").head.default("0")
      val nofexp = whole.split("e").head.default("0").split("E").head.default("0")
      nofexp.parse-int
    _ -> Nothing

pub fun json/bool( j : json ) : maybe<bool>
  match j
    JBool(b) -> Just(b)
    _        -> Nothing

pub fun json/array( j : json ) : maybe<list<json>>
  match j
    JArray(xs) -> Just(xs)
    _          -> Nothing

pub fun json/object( j : json ) : maybe<list<(string,json)>>
  match j
    JObject(fs) -> Just(fs)
    _           -> Nothing

// `Object.field` shorthand: returns Nothing if `j` isn't an object or the
// field is missing.
pub fun json/get( j : json, key : string ) : maybe<json>
  match j
    JObject(fs) -> assoc-lookup(fs, key)
    _           -> Nothing

fun assoc-lookup( fs : list<(string,json)>, key : string ) : maybe<json>
  match fs
    Nil -> Nothing
    Cons((k,v), rest) -> if k == key then Just(v) else assoc-lookup(rest, key)

// `maybe<maybe<a>> -> maybe<a>` — Koka stdlib calls it `flatten` but
// it doesn't expose that via the chained dot syntax cleanly across our
// module boundary, so we replicate.
pub fun flatten-maybe( m : maybe<maybe<a>> ) : maybe<a>
  match m
    Just(x) -> x
    Nothing -> Nothing

// Get a string field, or "" if absent.
pub fun get-string( j : json, key : string ) : string
  j.get(key).map(json/string).flatten-maybe.default("")

// Get a list of strings: accepts either a JString (returned as singleton)
// or a JArray of strings (anything non-string is skipped). Useful for AP
// `to`, `cc`, `url`, etc. which can be either a single value or an array.
pub fun get-string-list( j : json, key : string ) : list<string>
  match j.get(key)
    Nothing -> []
    Just(JString(s)) -> [s]
    Just(JArray(xs)) -> xs.flatmap(fn(x) match x { JString(s) -> [s]; _ -> [] })
    Just(_) -> []

// Get a json field, or `JNull` if absent.
pub fun get-or-null( j : json, key : string ) : json
  j.get(key).default(JNull)

// ----------------------------------------------------------------------
//  Serialization
// ----------------------------------------------------------------------

// Compact JSON output (no whitespace). Use this for federation; remote
// servers don't care about indentation and compactness saves bytes.
pub fun json/show( j : json ) : div string
  match j
    JNull        -> "null"
    JBool(True)  -> "true"
    JBool(False) -> "false"
    JNumber(s)   -> s
    JString(s)   -> "\"" ++ escape-string(s) ++ "\""
    JArray(xs)   ->
      "[" ++ xs.map(json/show).join(",") ++ "]"
    JObject(fs)  ->
      "{" ++ fs.map(fn(p) "\"" ++ escape-string(p.fst) ++ "\":" ++ json/show(p.snd)).join(",") ++ "}"

// Pretty-printed output with two-space indent. Used only for human-
// facing debug pages.
pub fun json/show-pretty( j : json ) : div string
  pretty-go(j, 0)

fun pretty-go( j : json, depth : int ) : div string
  match j
    JNull        -> "null"
    JBool(True)  -> "true"
    JBool(False) -> "false"
    JNumber(s)   -> s
    JString(s)   -> "\"" ++ escape-string(s) ++ "\""
    JArray(Nil)  -> "[]"
    JArray(xs)   ->
      val indent  = " ".repeat((depth + 1) * 2)
      val close   = " ".repeat(depth * 2)
      "[\n" ++ xs.map(fn(x) indent ++ pretty-go(x, depth + 1)).join(",\n") ++ "\n" ++ close ++ "]"
    JObject(Nil) -> "{}"
    JObject(fs)  ->
      val indent  = " ".repeat((depth + 1) * 2)
      val close   = " ".repeat(depth * 2)
      "{\n" ++ fs.map(fn(p)
        indent ++ "\"" ++ escape-string(p.fst) ++ "\": " ++ pretty-go(p.snd, depth + 1)
      ).join(",\n") ++ "\n" ++ close ++ "}"

fun escape-string( s : string ) : string
  s.list.map(escape-char).join("")

fun escape-char( c : char ) : string
  if c == '"' then "\\\""
  elif c == '\\' then "\\\\"
  elif c == '\n' then "\\n"
  elif c == '\r' then "\\r"
  elif c == '\t' then "\\t"
  elif c.int < 0x20 then "\\u" ++ pad4-hex(c.int)
  else c.string

fun pad4-hex( n : int ) : string
  val a = (n / 4096) % 16
  val b = (n / 256) % 16
  val c = (n / 16) % 16
  val d = n % 16
  hex-char(a).string ++ hex-char(b).string ++ hex-char(c).string ++ hex-char(d).string

fun hex-char( n : int ) : char
  if n < 10 then ('0'.int + n).char
  else ('a'.int + n - 10).char

// ----------------------------------------------------------------------
//  Parsing
// ----------------------------------------------------------------------

// Top-level parse. Returns Nothing on malformed input or trailing junk.
pub fun json-parse( s : string ) : div maybe<json>
  parse-eof(s.slice, parse-value).maybe

fun parse-value() : <parse,div> json
  whitespace0()
  val v = choose([
    { parse-null-value() },
    { parse-bool-value() },
    { parse-string-as-json() },
    { parse-number-value() },
    { parse-array-value() },
    { parse-object-value() }
  ])
  whitespace0()
  v

fun parse-null-value() : parse json
  pstring("null")
  JNull

fun parse-bool-value() : parse json
  choose([
    { pstring("true");  JBool(True) },
    { pstring("false"); JBool(False) }
  ])

// Number: optional minus, digits, optional fractional and exponent.
// Captured as a raw string; consumers convert when needed.
fun parse-number-value() : parse json
  val sign = optional("", { char('-'); "-" })
  val whole = digits()
  val frac = optional("", { char('.'); "." ++ digits() })
  val exp = optional("", { parse-exp() })
  JNumber(sign ++ whole ++ frac ++ exp)

fun parse-exp() : parse string
  val e = choose([{ char('e'); "e" }, { char('E'); "E" }])
  val s = optional("", { exp-sign() })
  e ++ s ++ digits()

fun exp-sign() : parse string
  choose([{ char('+'); "+" }, { char('-'); "-" }])

fun parse-string-as-json() : parse json
  JString(parse-string-literal())

fun parse-string-literal() : parse string
  char('"')
  val cs = many({ parse-string-char() })
  char('"')
  cs.string

fun parse-string-char() : parse char
  choose([
    { escape-char-parse() },
    { char-is("regular char", fn(c) c != '"' && c != '\\') }
  ])

fun escape-char-parse() : parse char
  char('\\')
  val c = char-is("escape", fn(_) True)
  if c == '"' then '"'
  elif c == '\\' then '\\'
  elif c == '/' then '/'
  elif c == 'n' then '\n'
  elif c == 'r' then '\r'
  elif c == 't' then '\t'
  elif c == 'b' then 8.char
  elif c == 'f' then 12.char
  elif c == 'u' then unicode-escape()
  else c

fun unicode-escape() : parse char
  val h1 = hex-digit-val()
  val h2 = hex-digit-val()
  val h3 = hex-digit-val()
  val h4 = hex-digit-val()
  (((h1 * 16 + h2) * 16 + h3) * 16 + h4).char

fun hex-digit-val() : parse int
  val c = char-is("hex digit", is-hex-digit)
  if c >= '0' && c <= '9' then c.int - '0'.int
  elif c >= 'a' && c <= 'f' then c.int - 'a'.int + 10
  else c.int - 'A'.int + 10

fun parse-array-value() : <parse,div> json
  char('[')
  whitespace0()
  val xs = sep-by({ parse-value() }, { comma() })
  whitespace0()
  char(']')
  JArray(xs)

fun comma() : parse ()
  whitespace0()
  char(',')
  whitespace0()
  ()

fun parse-object-value() : <parse,div> json
  char('{')
  whitespace0()
  val fs = sep-by({ parse-kv() }, { comma() })
  whitespace0()
  char('}')
  JObject(fs)

fun parse-kv() : <parse,div> (string,json)
  whitespace0()
  val k = parse-string-literal()
  whitespace0()
  char(':')
  whitespace0()
  val v = parse-value()
  (k, v)
