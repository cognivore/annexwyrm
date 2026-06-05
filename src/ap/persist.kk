// annexwyrm/ap/persist — DB operations shared by inbox + outbox.
//
// Thin layer: every function is a single SQL statement plus minor
// shaping. Lives here so `inbox.kk` and `outbox.kk` don't re-declare
// the same helpers.

module ap/persist

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/config
import ap/activity

// The URL identifying the local actor.
pub fun local-actor-url() : config url
  get-base-url() ++ "/users/" ++ get-local-username()

// Mint a fresh activity ID. The `kind` is a URL segment ("activities"
// for normal activities, "items" for objects).
pub fun mint-id( kind : string ) : <rng,config|e> url
  get-base-url() ++ "/" ++ kind ++ "/" ++ rand-hex(12)

// Persist an activity to the `activity` table. Idempotent on id.
pub fun record-activity( body : json, a : ap-activity, inbox-remote : bool )
  : <db,time,div|e> ()
  val now = now-iso()
  val addressed = json/show(arr((a.to ++ a.cc).map(string/json)))
  val _ = exec(
    "INSERT OR IGNORE INTO activity (id, actor_id, type, object_id, target_id, " ++
    "inbox_remote, raw, addressed_to, received_at) VALUES (?,?,?,?,?,?,?,?,?)",
    [txt(a.id), txt(a.actor), txt(a.kind.show), txt(a.object-id),
     txt(a.target), num(if inbox-remote then 1 else 0),
     txt(json/show(body)), txt(addressed), txt(now)]
  )
  ()

// Queue an outbound delivery of activity `aid` to `inbox-url`.
pub fun queue-delivery( aid : url, inbox-url : url )
  : <db,time,config|e> ()
  val now = now-iso()
  val _ = exec(
    "INSERT INTO delivery (activity_id, sender_id, inbox_url, next_attempt, " ++
    "attempts, state) VALUES (?,?,?,?,?,?)",
    [txt(aid), txt(local-actor-url()), txt(inbox-url),
     txt(now), num(0), txt("pending")]
  )
  ()

// Look up the cached inbox URL for an actor we have a row for. Returns
// "" if we've never resolved this actor.
pub fun lookup-actor-inbox( actor-id : url ) : db string
  val rows = query(
    "SELECT COALESCE(shared_inbox, inbox) FROM actor WHERE id = ?",
    [txt(actor-id)]
  )
  rows.first-text.default("")

// Return the de-duplicated list of inbox URLs we need to deliver to for
// every follower of the local actor. Prefers `shared_inbox` so we
// hit each remote server once.
pub fun followers-inboxes( target-id : url ) : db list<url>
  val rows = query(
    "SELECT DISTINCT COALESCE(a.shared_inbox, a.inbox) " ++
    "FROM follow f " ++
    "JOIN actor a ON a.id = f.follower_id " ++
    "WHERE f.target_id = ? AND f.state = ?",
    [txt(target-id), txt("accepted")]
  )
  rows.flatmap(fn(row) text-col-as-list(row.col(0)))

fun text-col-as-list( v : sql-value ) : list<string>
  match v
    SqlText(s) -> [s]
    _          -> []
