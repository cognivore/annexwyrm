// annexwyrm/ap/actor_cache — resolve a remote actor.
//
// Two paths:
//   1. Local cache hit  — return immediately from the `actor` table.
//   2. Cache miss        — `fetch` the actor document, parse it,
//                          INSERT a row, return it.
//
// On verification failure (key rotation, etc.) the caller passes
// `refresh = True` to bypass the cache.

module ap/actor_cache

import core/types
import core/json
import core/url
import effects/db
import effects/fetch
import effects/time
import effects/log
import effects/http
import ap/actor

// Look up an actor by id. Returns Nothing if neither cached nor
// reachable, or if the remote response is malformed.
pub fun resolve-actor( actor-id : url, refresh : bool = False )
  : <db,fetch,time,log,div|e> maybe<ap-actor>
  if !refresh then
    val cached = from-cache(actor-id)
    match cached
      Just(a) -> Just(a)
      Nothing -> fetch-actor(actor-id)
  else
    fetch-actor(actor-id)

// ----------------------------------------------------------------------
//  Cache read
// ----------------------------------------------------------------------

fun from-cache( actor-id : url ) : db maybe<ap-actor>
  val rows = query(
    "SELECT id, username, domain, name, summary, icon_url, inbox, outbox, " ++
    "followers, following, COALESCE(shared_inbox, ''), public_key_pem, " ++
    "manually_approves, discoverable FROM actor WHERE id = ?",
    [txt(actor-id)]
  )
  match rows
    Nil -> Nothing
    Cons(r, _) -> Just(row-to-actor(r))

fun row-to-actor( row : sql-row ) : ap-actor
  Ap-actor(
    id                 = row.col(0).text,
    kind               = AkPerson,
    preferred-username = row.col(1).text,
    name               = row.col(3).text,
    summary            = row.col(4).text,
    icon-url           = row.col(5).text,
    inbox              = row.col(6).text,
    outbox             = row.col(7).text,
    followers          = row.col(8).text,
    following          = row.col(9).text,
    shared-inbox       = row.col(10).text,
    public-key-id      = row.col(0).text ++ "#main-key",
    public-key-pem     = row.col(11).text,
    manually-approves  = row.col(12).int-bool,
    discoverable       = row.col(13).int-bool
  )

fun text( v : sql-value ) : string
  match v
    SqlText(s) -> s
    _          -> ""

fun int-bool( v : sql-value ) : bool
  match v
    SqlInt(n) -> n != 0
    _         -> False

// ----------------------------------------------------------------------
//  Fetch from the network
// ----------------------------------------------------------------------

fun fetch-actor( actor-id : url ) : <db,fetch,time,log,div|e> maybe<ap-actor>
  val resp = http-get(actor-id,
    "application/activity+json, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"")
  if !resp.ok then
    warn("actor/fetch failed", [("id", actor-id), ("status", resp.status.show)])
    Nothing
  else
    parse-and-cache(actor-id, resp.body)

fun parse-and-cache( actor-id : url, body : string )
  : <db,time,log,div|e> maybe<ap-actor>
  match json-parse(body)
    Nothing -> warn-and-none("actor/fetch: invalid json", actor-id)
    Just(j) -> handle-parsed-actor(actor-id, j)

fun handle-parsed-actor( actor-id : url, j : json )
  : <db,time,log|e> maybe<ap-actor>
  match ap-actor/from-json(j)
    Nothing -> warn-and-none("actor/fetch: missing fields", actor-id)
    Just(actor) ->
      cache-actor(actor)
      Just(actor)

fun warn-and-none( msg : string, actor-id : url ) : log maybe<ap-actor>
  warn(msg, [("id", actor-id)])
  Nothing

fun cache-actor( a : ap-actor ) : <db,time|e> ()
  val now = now-iso()
  val domain = host-of(a.id).default("")
  val _ = exec(
    "INSERT INTO actor (id, local, username, domain, name, summary, icon_url, " ++
    "inbox, outbox, followers, following, shared_inbox, public_key_pem, " ++
    "manually_approves, discoverable, created_at, fetched_at) " ++
    "VALUES (?,0,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) " ++
    "ON CONFLICT(id) DO UPDATE SET " ++
    "username = excluded.username, name = excluded.name, summary = excluded.summary, " ++
    "icon_url = excluded.icon_url, inbox = excluded.inbox, outbox = excluded.outbox, " ++
    "followers = excluded.followers, following = excluded.following, " ++
    "shared_inbox = excluded.shared_inbox, public_key_pem = excluded.public_key_pem, " ++
    "manually_approves = excluded.manually_approves, discoverable = excluded.discoverable, " ++
    "fetched_at = excluded.fetched_at",
    [txt(a.id), txt(a.preferred-username), txt(domain),
     txt(a.name), txt(a.summary), txt(a.icon-url),
     txt(a.inbox), txt(a.outbox), txt(a.followers), txt(a.following),
     maybe-txt(a.shared-inbox), txt(a.public-key-pem),
     num(if a.manually-approves then 1 else 0),
     num(if a.discoverable then 1 else 0),
     txt(now), txt(now)]
  )
  ()

fun maybe-txt( s : string ) : sql-value
  if s == "" then SqlNull else SqlText(s)

fun host-of( u : url ) : maybe<string>
  url-parse(u).map(fn(p) p.host)
