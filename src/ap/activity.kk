// annexwyrm/ap/activity — Create / Update / Delete / Follow / Accept /
// Reject / Like / Announce / Add / Remove / Undo.
//
// One value type, one serialiser. We don't parse the `object` field
// any further than "raw json"; the dispatcher in `ap/inbox` knows what
// to expect per activity kind and pulls out what it needs.

module ap/activity

import core/types
import core/json
import ap/object

// NOTE: reference `struct`, not `value struct`, as a workaround for
// koka-lang/koka#654 (genLambda crash on mlift'd lambdas capturing
// value structs with mixed raw + boxed fields). Revisit once Koka
// > 3.2.3 ships a fix.
pub struct ap-activity
  id        : url
  kind      : activity-kind
  actor     : url            // who performed the activity
  object    : json           // a URL string OR an embedded object/activity
  target    : string         // Add/Remove: the target collection URL
  to        : list<url>
  cc        : list<url>
  published : iso-time

// ----------------------------------------------------------------------
//  Accessors that paper over the object's polymorphism
// ----------------------------------------------------------------------

// Extract the id of the activity's `object`, regardless of whether it
// was a string or an embedded object. Returns "" when missing.
pub fun ap-activity/object-id( a : ap-activity ) : string
  match a.object
    JString(s) -> s
    JObject(_) -> a.object.get-string("id")
    _          -> ""

// Extract the type of the embedded object, when there is one. "" for
// activities whose object is a bare URL.
pub fun ap-activity/object-type( a : ap-activity ) : string
  match a.object
    JObject(_) -> a.object.get-string("type")
    _          -> ""

// True iff this is one of the "scoped" activities whose object is
// expected to be another activity (Undo, Accept, Reject).
pub fun ap-activity/wraps-activity( a : ap-activity ) : bool
  match a.kind
    AcUndo   -> True
    AcAccept -> True
    AcReject -> True
    _        -> False

// ----------------------------------------------------------------------
//  Serialization
// ----------------------------------------------------------------------

pub fun ap-activity/to-json( a : ap-activity ) : json
  obj-opt([
    ("@context", activity-context()),
    ("id",        string/json(a.id)),
    ("type",      string/json(a.kind.show)),
    ("actor",     string/json(a.actor)),
    ("object",    a.object),
    ("target",    str-or-null(a.target)),
    ("to",        urls-or-null(a.to)),
    ("cc",        urls-or-null(a.cc)),
    ("published", string/json(a.published))
  ])

// Activity context: AS2 plus security plus a few common Mastodon
// shorthands. We emit this on every activity we deliver outbound.
fun activity-context() : json
  arr([
    string/json(ap-context-activitystreams),
    string/json(ap-context-security),
    obj([
      ("sensitive",                 string/json("as:sensitive")),
      ("Hashtag",                   string/json("as:Hashtag")),
      ("manuallyApprovesFollowers", string/json("as:manuallyApprovesFollowers"))
    ])
  ])

fun str-or-null( s : string ) : json
  if s == "" then JNull else string/json(s)

fun urls-or-null( xs : list<string> ) : json
  match xs
    Nil -> JNull
    _   -> arr(xs.map(string/json))

// ----------------------------------------------------------------------
//  Deserialization
// ----------------------------------------------------------------------

pub fun ap-activity/from-json( j : json ) : maybe<ap-activity>
  val type-str = j.get-string("type")
  match activity-kind/parse(type-str)
    Nothing -> Nothing
    Just(k) -> Just(Ap-activity(
      id        = j.get-string("id"),
      kind      = k,
      actor     = extract-actor(j.get("actor")),
      object    = j.get-or-null("object"),
      target    = extract-target(j.get("target")),
      to        = j.get-string-list("to"),
      cc        = j.get-string-list("cc"),
      published = j.get-string("published")
    ))

// `actor` is usually a URL string, but it may be the full embedded actor
// object — in which case we pull out its `id`.
fun extract-actor( j : maybe<json> ) : string
  match j
    Just(JString(s)) -> s
    Just(JObject(_)) -> j.default(JNull).get-string("id")
    _                -> ""

fun extract-target( j : maybe<json> ) : string
  match j
    Just(JString(s)) -> s
    Just(JObject(_)) -> j.default(JNull).get-string("id")
    _                -> ""

// ----------------------------------------------------------------------
//  Smart constructors used by `ap/outbox`
// ----------------------------------------------------------------------

pub fun create-of( id : url, actor-id : url, obj : ap-object ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcCreate,
    actor     = actor-id,
    object    = ap-object/to-json(obj, embed-context = False),
    target    = "",
    to        = obj.to,
    cc        = obj.cc,
    published = obj.published
  )

pub fun update-of( id : url, actor-id : url, obj : ap-object ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcUpdate,
    actor     = actor-id,
    object    = ap-object/to-json(obj, embed-context = False),
    target    = "",
    to        = obj.to,
    cc        = obj.cc,
    published = obj.published
  )

pub fun delete-of( id : url, actor-id : url, object-id : url, when : iso-time,
                   to : list<url>, cc : list<url> ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcDelete,
    actor     = actor-id,
    object    = string/json(object-id),
    target    = "",
    to        = to,
    cc        = cc,
    published = when
  )

pub fun follow-of( id : url, follower : url, target : url, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcFollow,
    actor     = follower,
    object    = string/json(target),
    target    = "",
    to        = [target],
    cc        = [],
    published = when
  )

pub fun accept-of( id : url, actor-id : url, original : ap-activity, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcAccept,
    actor     = actor-id,
    object    = ap-activity/to-json(original),
    target    = "",
    to        = [original.actor],
    cc        = [],
    published = when
  )

pub fun reject-of( id : url, actor-id : url, original : ap-activity, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcReject,
    actor     = actor-id,
    object    = ap-activity/to-json(original),
    target    = "",
    to        = [original.actor],
    cc        = [],
    published = when
  )

pub fun undo-of( id : url, actor-id : url, original : ap-activity, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcUndo,
    actor     = actor-id,
    object    = ap-activity/to-json(original),
    target    = "",
    to        = original.to,
    cc        = original.cc,
    published = when
  )

pub fun like-of( id : url, actor-id : url, object-id : url, owner : url, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcLike,
    actor     = actor-id,
    object    = string/json(object-id),
    target    = "",
    to        = [owner],
    cc        = [],
    published = when
  )

pub fun announce-of( id : url, actor-id : url, object-id : url,
                     followers : url, when : iso-time ) : ap-activity
  Ap-activity(
    id        = id,
    kind      = AcAnnounce,
    actor     = actor-id,
    object    = string/json(object-id),
    target    = "",
    to        = [followers, ap-public-iri],
    cc        = [],
    published = when
  )
