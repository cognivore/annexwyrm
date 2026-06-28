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

// The URL identifying the BOOTSTRAP (admin) local actor — the env-configured
// tenant. Multitenant code threads the ACTING actor explicitly instead; this
// remains for the CLI and the admin-scoped fallbacks.
pub fun local-actor-url() : config url
  get-base-url() ++ "/users/" ++ get-local-username()

// The actor-id of a local tenant with this username, or "" if there is no
// such local actor. The multi-user AP handlers (actor/outbox/followers/inbox/
// webfinger) resolve the requested username through here instead of comparing
// against the single configured username.
pub fun local-actor-id-for( username : string ) : db url
  query(
    "SELECT id FROM actor WHERE local = 1 AND username = ? LIMIT 1",
    [txt(username)]
  ).first-text.default("")

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

// Queue an outbound delivery of activity `aid`, sent by `sender` (the acting
// local actor), to `inbox-url`. `sender_id` drives which actor's private key
// the delivery worker signs the POST with, so it MUST be the activity's
// actor — this is how each tenant federates under its own key.
pub fun queue-delivery( aid : url, inbox-url : url, sender : url )
  : <db,time|e> ()
  val now = now-iso()
  val _ = exec(
    "INSERT INTO delivery (activity_id, sender_id, inbox_url, next_attempt, " ++
    "attempts, state) VALUES (?,?,?,?,?,?)",
    [txt(aid), txt(sender), txt(inbox-url),
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

// ----------------------------------------------------------------------
//  Item tags (the item_tag side table)
// ----------------------------------------------------------------------

// Replace an item's tags wholesale. Tags must already be normalised
// (lowercase, no '#') — see annex/item's parse-tags.
pub fun save-item-tags( item-id : url, tags : list<string> ) : db ()
  val _ = exec("DELETE FROM item_tag WHERE item_id = ?", [txt(item-id)])
  tags.foreach(fn(t) insert-one-tag(item-id, t))

fun insert-one-tag( item-id : url, tag : string ) : db ()
  val _ = exec(
    "INSERT OR IGNORE INTO item_tag (item_id, tag) VALUES (?,?)",
    [txt(item-id), txt(tag)]
  )
  ()

// An item's tags, sorted. Source of truth for both rendering and the
// federated `tag` array (emit-create/emit-update read it here).
pub fun load-item-tags( item-id : url ) : db list<string>
  val rows = query(
    "SELECT tag FROM item_tag WHERE item_id = ? ORDER BY tag", [txt(item-id)]
  )
  rows.flatmap(fn(row) text-col-as-list(row.col(0)))
