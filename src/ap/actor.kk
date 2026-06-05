// annexwyrm/ap/actor — Person/Application Actor JSON-LD.
//
// Pure: takes records, returns json (or maybe<ap-actor> from json). No
// I/O. The algorithms in `ap/inbox` etc. call into this and then onto
// the effects.

module ap/actor

import core/types
import core/json

// A parsed Actor. Fields that AP makes optional are kept as `""` /
// `False` sentinels here; the JSON encoder drops `""` so they don't
// appear on the wire.
pub value struct ap-actor
  id                 : url           // https://domain/users/alice
  kind               : actor-kind
  preferred-username : string
  name               : string        // display name; "" = absent
  summary            : string        // bio HTML; "" = absent
  icon-url           : string        // avatar URL; "" = absent
  inbox              : url
  outbox             : url
  followers          : url
  following          : url
  shared-inbox       : string        // "" = absent
  public-key-id      : url           // typically "{id}#main-key"
  public-key-pem     : string
  manually-approves  : bool
  discoverable       : bool

// ----------------------------------------------------------------------
//  Builders
// ----------------------------------------------------------------------

// Construct the standard local-actor record from a (domain, username)
// pair and a freshly-generated keypair. Use this from the install /
// migration code.
pub fun build-local-actor(
    base-url       : string,
    username       : string,
    name           : string,
    summary        : string,
    public-key-pem : string
  ) : ap-actor
  val aid = base-url ++ "/users/" ++ username
  Ap-actor(
    id                 = aid,
    kind               = AkPerson,
    preferred-username = username,
    name               = name,
    summary            = summary,
    icon-url           = "",
    inbox              = aid ++ "/inbox",
    outbox             = aid ++ "/outbox",
    followers          = aid ++ "/followers",
    following          = aid ++ "/following",
    shared-inbox       = base-url ++ "/inbox",
    public-key-id      = aid ++ "#main-key",
    public-key-pem     = public-key-pem,
    manually-approves  = False,
    discoverable       = True
  )

// ----------------------------------------------------------------------
//  Serialization to JSON-LD
// ----------------------------------------------------------------------

pub fun ap-actor/to-json( a : ap-actor ) : json
  obj-opt([
    ("@context", actor-context()),
    ("id", string/json(a.id)),
    ("type", string/json(a.kind.show)),
    ("preferredUsername", string/json(a.preferred-username)),
    ("name", str-or-null(a.name)),
    ("summary", str-or-null(a.summary)),
    ("url", string/json(a.id)),
    ("inbox", string/json(a.inbox)),
    ("outbox", string/json(a.outbox)),
    ("followers", string/json(a.followers)),
    ("following", string/json(a.following)),
    ("publicKey", obj([
      ("id", string/json(a.public-key-id)),
      ("owner", string/json(a.id)),
      ("publicKeyPem", string/json(a.public-key-pem))
    ])),
    ("endpoints", endpoints-obj(a.shared-inbox)),
    ("icon", icon-obj(a.icon-url)),
    ("manuallyApprovesFollowers", bool/json(a.manually-approves)),
    ("discoverable", bool/json(a.discoverable))
  ])

fun actor-context() : json
  arr([
    string/json(ap-context-activitystreams),
    string/json(ap-context-security),
    obj([
      ("manuallyApprovesFollowers", string/json("as:manuallyApprovesFollowers")),
      ("discoverable",              string/json("toot:discoverable")),
      ("toot",                      string/json("http://joinmastodon.org/ns#"))
    ])
  ])

fun str-or-null( s : string ) : json
  if s == "" then JNull else string/json(s)

fun endpoints-obj( shared-inbox : string ) : json
  if shared-inbox == "" then JNull
  else obj([("sharedInbox", string/json(shared-inbox))])

fun icon-obj( icon-url : string ) : json
  if icon-url == "" then JNull
  else obj([
    ("type",      string/json("Image")),
    ("mediaType", string/json("image/png")),
    ("url",       string/json(icon-url))
  ])

// ----------------------------------------------------------------------
//  Deserialization from JSON-LD
// ----------------------------------------------------------------------

// Parse an incoming actor document. Returns Nothing if it's missing the
// minimum required fields (id, inbox).
pub fun ap-actor/from-json( j : json ) : maybe<ap-actor>
  val id = j.get-string("id")
  val inbox = j.get-string("inbox")
  if id == "" || inbox == "" then Nothing
  else
    val kind = actor-kind/parse(j.get-string("type")).default(AkPerson)
    Just(Ap-actor(
      id                 = id,
      kind               = kind,
      preferred-username = j.get-string("preferredUsername"),
      name               = j.get-string("name"),
      summary            = j.get-string("summary"),
      icon-url           = extract-icon-url(j.get("icon")),
      inbox              = inbox,
      outbox             = j.get-string("outbox"),
      followers          = j.get-string("followers"),
      following          = j.get-string("following"),
      shared-inbox       = j.get("endpoints").default(JNull).get-string("sharedInbox"),
      public-key-id      = j.get("publicKey").default(JNull).get-string("id"),
      public-key-pem     = j.get("publicKey").default(JNull).get-string("publicKeyPem"),
      manually-approves  = j.get("manuallyApprovesFollowers")
                            .map(json/bool).flatten-maybe.default(False),
      discoverable       = j.get("discoverable")
                            .map(json/bool).flatten-maybe.default(True)
    ))

// `icon` can be a string, an object with a `url` field, or an array of
// either. We return the first usable URL.
fun extract-icon-url( j : maybe<json> ) : string
  match j
    Nothing    -> ""
    Just(jval) -> icon-url-of(jval)

fun icon-url-of( j : json ) : string
  match j
    JString(s) -> s
    JObject(_) -> j.get-string("url")
    JArray(Cons(x,_)) -> icon-url-of(x)
    _ -> ""
