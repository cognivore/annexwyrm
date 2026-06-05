// annexwyrm/ap/object — Note/Article/Document/Audio/Video/Image.
//
// One value type, one serialiser. The `kind` field tells you what's
// significant. We always emit the fields the spec requires for the
// chosen kind; optional fields use `""` / empty list sentinels and the
// encoder drops them.

module ap/object

import core/types
import core/json

// A Link (RFC 5988 / AS2). One mirror entry in `url`.
pub value struct ap-link
  href       : url
  media-type : string            // RFC 6838; "" = absent
  name       : string            // human label; "" = absent
  rel        : string            // RFC 5988 link rel; "" = absent

pub fun ap-link/to-json( l : ap-link ) : json
  obj-opt([
    ("type",      string/json("Link")),
    ("href",      string/json(l.href)),
    ("mediaType", str-or-null(l.media-type)),
    ("name",      str-or-null(l.name)),
    ("rel",       str-or-null(l.rel))
  ])

pub fun ap-link/from-json( j : json ) : maybe<ap-link>
  val href = j.get-string("href")
  if href == "" then Nothing
  else Just(Ap-link(
    href       = href,
    media-type = j.get-string("mediaType"),
    name       = j.get-string("name"),
    rel        = j.get-string("rel")
  ))

// ----------------------------------------------------------------------
//  The unified AP object record
// ----------------------------------------------------------------------

pub value struct ap-object
  id            : url
  kind          : object-kind
  attributed-to : url            // owner actor id
  name          : string         // title; required for Article, optional elsewhere
  summary       : string         // content-warning / abstract
  content       : string         // HTML body
  media-type    : string         // for Document/Audio/Video/Image; ""
  urls          : list<ap-link>  // for Document family; mirrors
  in-reply-to   : string         // ""
  published     : iso-time
  updated       : iso-time       // ""
  to            : list<url>
  cc            : list<url>
  sensitive     : bool
  attachment    : list<ap-link>  // optional thumbnails / extras
  rating        : int            // -3..3 or 99 = unrated; serialised as `annexwyrm:rating`

// Default-ish builder used by tests and the publish flow.
pub fun ap-object/empty( id : url, kind : object-kind, owner : url, published : iso-time ) : ap-object
  Ap-object(
    id            = id,
    kind          = kind,
    attributed-to = owner,
    name          = "",
    summary       = "",
    content       = "",
    media-type    = "",
    urls          = [],
    in-reply-to   = "",
    published     = published,
    updated       = "",
    to            = [],
    cc            = [],
    sensitive     = False,
    attachment    = [],
    rating        = 99
  )

// ----------------------------------------------------------------------
//  Serialization
// ----------------------------------------------------------------------

// Whether the kind is one of the file-bearing types (Document/Audio/
// Video/Image). For Note and Article we omit the `url` field.
fun kind-has-files( k : object-kind ) : bool
  match k
    OkDocument -> True
    OkAudio    -> True
    OkVideo    -> True
    OkImage    -> True
    _          -> False

// Convert to JSON-LD. `embed-context` controls whether `@context` is
// included; activities wrap an object and the context lives on the
// activity, so we pass `False` from the activity encoder.
pub fun ap-object/to-json( o : ap-object, embed-context : bool = True ) : json
  obj-opt([
    ("@context",            if embed-context then object-context() else JNull),
    ("id",                  string/json(o.id)),
    ("type",                string/json(o.kind.show)),
    ("attributedTo",        string/json(o.attributed-to)),
    ("name",                str-or-null(o.name)),
    ("summary",             str-or-null(o.summary)),
    ("content",             str-or-null(o.content)),
    ("mediaType",           str-or-null(o.media-type)),
    ("url",                 urls-json(o.kind, o.urls)),
    ("inReplyTo",           str-or-null(o.in-reply-to)),
    ("published",           string/json(o.published)),
    ("updated",             str-or-null(o.updated)),
    ("to",                  urls-or-null(o.to)),
    ("cc",                  urls-or-null(o.cc)),
    ("sensitive",           bool/json(o.sensitive)),
    ("attachment",          attachments-or-null(o.attachment)),
    ("annexwyrm:rating",    rating-json(o.rating))
  ])

// `annexwyrm:rating` is namespaced; we declare the prefix in the context.
// Other servers will ignore it; ours surface it as the 7-point score.
fun rating-json( r : int ) : json
  if r < -3 || r > 3 then JNull else int/json(r)

fun object-context() : json
  arr([
    string/json(ap-context-activitystreams),
    obj([
      ("sensitive", string/json("as:sensitive")),
      ("Hashtag",   string/json("as:Hashtag")),
      ("annexwyrm", string/json("https://annexwyrm.example.com/ns#"))
    ])
  ])

fun str-or-null( s : string ) : json
  if s == "" then JNull else string/json(s)

fun urls-or-null( xs : list<string> ) : json
  match xs
    Nil -> JNull
    _   -> arr(xs.map(string/json))

fun urls-json( k : object-kind, links : list<ap-link> ) : json
  if !kind-has-files(k) then JNull
  else match links
    Nil      -> JNull
    Cons(l,Nil) -> ap-link/to-json(l)     // single Link, not wrapped in array
    _        -> arr(links.map(ap-link/to-json))

fun attachments-or-null( xs : list<ap-link> ) : json
  match xs
    Nil -> JNull
    _   -> arr(xs.map(ap-link/to-json))

// ----------------------------------------------------------------------
//  Deserialization
// ----------------------------------------------------------------------

pub fun ap-object/from-json( j : json ) : div maybe<ap-object>
  val id = j.get-string("id")
  val kind = object-kind/parse(j.get-string("type")).default(OkNote)
  if id == "" then Nothing
  else Just(Ap-object(
    id            = id,
    kind          = kind,
    attributed-to = j.get-string("attributedTo"),
    name          = j.get-string("name"),
    summary       = j.get-string("summary"),
    content       = j.get-string("content"),
    media-type    = j.get-string("mediaType"),
    urls          = extract-urls(j.get("url")),
    in-reply-to   = j.get-string("inReplyTo"),
    published     = j.get-string("published"),
    updated       = j.get-string("updated"),
    to            = j.get-string-list("to"),
    cc            = j.get-string-list("cc"),
    sensitive     = j.get("sensitive").map(json/bool).flatten-maybe.default(False),
    attachment    = extract-urls(j.get("attachment")),
    rating        = j.get("annexwyrm:rating").map(json/int).flatten-maybe.default(99)
  ))

// `url` is one of: a string, a Link object, an array of strings, an
// array of Links, or a mixed array. We normalise to a list of Links.
fun extract-urls( j : maybe<json> ) : div list<ap-link>
  match j
    Nothing          -> []
    Just(jval)       -> extract-one(jval)

fun extract-one( j : json ) : div list<ap-link>
  match j
    JString(s) -> [Ap-link(s, "", "", "")]
    JObject(_) -> link-or-empty(ap-link/from-json(j))
    JArray(xs) -> xs.flatmap(extract-one)
    _ -> []

fun link-or-empty( m : maybe<ap-link> ) : list<ap-link>
  match m
    Just(l) -> [l]
    Nothing -> []

// ----------------------------------------------------------------------
//  Tombstone for deleted objects
// ----------------------------------------------------------------------

// Build the Tombstone object returned when a remote dereferences a
// deleted item.
pub fun tombstone-of( id : url, former-type : object-kind, deleted : iso-time ) : json
  obj([
    ("@context",   string/json(ap-context-activitystreams)),
    ("id",         string/json(id)),
    ("type",       string/json("Tombstone")),
    ("formerType", string/json(former-type.show)),
    ("deleted",    string/json(deleted))
  ])
