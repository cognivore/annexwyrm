// annexwyrm/ap/inbox — dispatch an incoming, signature-verified activity.
//
// One pure-ish function: takes the activity (and its raw JSON), maps it
// to a sequence of effect operations. Returns Nothing on success or
// Just(message) on rejection. Signature verification is assumed already
// done by `web/handler/inbox`.
//
// All persistence goes through `effects/db`; all delivery to
// remote inboxes is *queued* (we never block the inbox response on an
// outbound POST).

module ap/inbox

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import ap/activity
import ap/actor
import ap/object
import ap/persist

// ----------------------------------------------------------------------
//  Entry point
// ----------------------------------------------------------------------

pub fun handle-inbox-activity(
    body     : json,
    activity : ap-activity
  ) : <db,time,rng,log,config,div|e> maybe<string>
  val existing = query("SELECT 1 FROM activity WHERE id = ?", [txt(activity.id)])
  match existing
    Cons(_,_) ->
      info("inbox/duplicate", [("id", activity.id)])
      Nothing
    Nil ->
      info("inbox/dispatch", [("id", activity.id), ("type", activity.kind.show)])
      record-activity(body, activity, True)
      match activity.kind
        AcCreate   -> handle-create(activity)
        AcUpdate   -> handle-update(activity)
        AcDelete   -> handle-delete(activity)
        AcFollow   -> handle-follow(activity)
        AcAccept   -> handle-accept(activity)
        AcReject   -> handle-reject(activity)
        AcLike     -> handle-like(activity)
        AcAnnounce -> handle-announce(activity)
        AcAdd      -> handle-add(activity)
        AcRemove   -> handle-remove(activity)
        AcUndo     -> handle-undo(activity)

// ----------------------------------------------------------------------
//  Per-activity handlers
// ----------------------------------------------------------------------

fun handle-create( a : ap-activity ) : <db,time,log|e> maybe<string>
  // We do not store arbitrary remote objects unless they are replies to
  // (or otherwise reference) something we own. The activity row itself
  // is already persisted; that's enough for the inbox UI.
  Nothing

fun handle-update( a : ap-activity ) : <db,time,log|e> maybe<string>
  Nothing

fun handle-delete( a : ap-activity ) : <db,time,log|e> maybe<string>
  // Replace any cached copy with a Tombstone.  In practice we don't
  // store remote objects, so this is a no-op except for the activity
  // log.
  Nothing

fun handle-follow( a : ap-activity ) : <db,time,rng,log,config,div|e> maybe<string>
  val now = now-iso()
  val target = a.object-id
  val local-actor-id = local-actor-url()
  if target != local-actor-id then
    warn("inbox/follow: target is not us", [("target", target), ("us", local-actor-id)])
    Just("Follow target does not match local actor")
  else
    exec(
      "INSERT OR REPLACE INTO follow (id, follower_id, target_id, state, created_at) " ++
      "VALUES (?,?,?,?,?)",
      [txt(a.id), txt(a.actor), txt(target), txt("pending"), txt(now)]
    )
    if get-manually-approves() then
      info("inbox/follow: queued for manual approval", [("actor", a.actor)])
      Nothing
    else
      auto-accept-follow(a, now)
      Nothing

fun auto-accept-follow( follow : ap-activity, now : iso-time )
  : <db,time,rng,log,config,div|e> ()
  val accept-id = mint-id("activities")
  val accept = accept-of(accept-id, local-actor-url(), follow, now)
  record-activity(ap-activity/to-json(accept), accept, False)
  exec(
    "UPDATE follow SET state = ?, accepted_at = ? WHERE id = ?",
    [txt("accepted"), txt(now), txt(follow.id)]
  )
  val inbox-url = lookup-actor-inbox(follow.actor)
  if inbox-url == "" then
    warn("inbox/follow: follower actor not cached", [("actor", follow.actor)])
  else
    queue-delivery(accept-id, inbox-url)

fun handle-accept( a : ap-activity ) : <db,time,log|e> maybe<string>
  // The remote actor accepted a Follow we sent. Promote that pending
  // row to `accepted`.
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Accept did not reference a Follow id")
  else
    val now = now-iso()
    exec(
      "UPDATE follow SET state = ?, accepted_at = ? WHERE id = ? AND state = ?",
      [txt("accepted"), txt(now), txt(inner-id), txt("pending")]
    )
    Nothing

fun handle-reject( a : ap-activity ) : <db,log|e> maybe<string>
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Reject did not reference a Follow id")
  else
    exec(
      "UPDATE follow SET state = ? WHERE id = ?",
      [txt("rejected"), txt(inner-id)]
    )
    Nothing

fun handle-like( a : ap-activity ) : <db,time,log|e> maybe<string>
  val now = now-iso()
  exec(
    "INSERT OR IGNORE INTO like_ (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(a.id), txt(a.actor), txt(a.object-id), txt(now)]
  )
  Nothing

fun handle-announce( a : ap-activity ) : <db,time,log|e> maybe<string>
  val now = now-iso()
  exec(
    "INSERT OR IGNORE INTO announce (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(a.id), txt(a.actor), txt(a.object-id), txt(now)]
  )
  Nothing

fun handle-add( a : ap-activity ) : <log|e> maybe<string>
  // Collection updates are not modelled — we have no remote-mutable
  // collections in our schema.
  info("inbox/add: ignored", [("target", a.target)])
  Nothing

fun handle-remove( a : ap-activity ) : <log|e> maybe<string>
  info("inbox/remove: ignored", [("target", a.target)])
  Nothing

fun handle-undo( a : ap-activity ) : <db,log|e> maybe<string>
  val inner-type = a.object-type
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Undo did not reference an activity id")
  elif inner-type == "Follow" then
    exec("DELETE FROM follow WHERE id = ?", [txt(inner-id)])
    Nothing
  elif inner-type == "Like" then
    exec("DELETE FROM like_ WHERE id = ?", [txt(inner-id)])
    Nothing
  elif inner-type == "Announce" then
    exec("DELETE FROM announce WHERE id = ?", [txt(inner-id)])
    Nothing
  else
    info("inbox/undo: unknown inner type", [("type", inner-type)])
    Nothing

// ----------------------------------------------------------------------
//  Local helpers (DB/queue/id helpers live in `ap/persist`)
// ----------------------------------------------------------------------

// Pull the `id` out of an embedded activity inside `object`.
fun inner-activity-id( j : json ) : string
  match j
    JString(s) -> s
    JObject(_) -> j.get-string("id")
    _ -> ""
