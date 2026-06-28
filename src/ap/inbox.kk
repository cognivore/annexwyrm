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
  // The Follow must target SOME local tenant. Look the target up among local
  // actors; a hit also yields that tenant's own manually_approves policy
  // (per-tenant, not a single global flag).
  val rows = query(
    "SELECT manually_approves FROM actor WHERE id = ? AND local = 1",
    [txt(target)]
  )
  match rows
    Nil ->
      warn("inbox/follow: target is not a local actor", [("target", target)])
      Just("Follow target does not match a local actor")
    Cons(r, _) ->
      val manual = match r.col(0) { SqlInt(n) -> n != 0; _ -> False }
      exec(
        "INSERT OR REPLACE INTO follow (id, follower_id, target_id, state, created_at) " ++
        "VALUES (?,?,?,?,?)",
        [txt(a.id), txt(a.actor), txt(target), txt("pending"), txt(now)]
      )
      if manual then
        info("inbox/follow: queued for manual approval",
          [("actor", a.actor), ("target", target)])
        Nothing
      else
        auto-accept-follow(a, target, now)
        Nothing

// `target` is the local tenant being followed; it is the actor that SENDS the
// Accept (and whose key signs it, via sender_id = target).
fun auto-accept-follow( follow : ap-activity, target : url, now : iso-time )
  : <db,time,rng,log,config,div|e> ()
  val accept-id = mint-id("activities")
  val accept = accept-of(accept-id, target, follow, now)
  record-activity(ap-activity/to-json(accept), accept, False)
  exec(
    "UPDATE follow SET state = ?, accepted_at = ? WHERE id = ?",
    [txt("accepted"), txt(now), txt(follow.id)]
  )
  val inbox-url = lookup-actor-inbox(follow.actor)
  if inbox-url == "" then
    warn("inbox/follow: follower actor not cached", [("actor", follow.actor)])
  else
    queue-delivery(accept-id, inbox-url, target)

fun handle-accept( a : ap-activity ) : <db,time,log|e> maybe<string>
  // The remote actor accepted a Follow we sent. Promote that pending row to
  // `accepted` — but ONLY a follow we sent to THIS actor (target_id =
  // a.actor). Without that scope a peer could Accept-spoof a follow id it
  // does not own and flip arbitrary follow rows. (a.actor is already bound
  // to the signing key by verify-signature.)
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Accept did not reference a Follow id")
  else
    val now = now-iso()
    exec(
      "UPDATE follow SET state = ?, accepted_at = ? " ++
      "WHERE id = ? AND state = ? AND target_id = ?",
      [txt("accepted"), txt(now), txt(inner-id), txt("pending"), txt(a.actor)]
    )
    Nothing

fun handle-reject( a : ap-activity ) : <db,log|e> maybe<string>
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Reject did not reference a Follow id")
  else
    exec(
      "UPDATE follow SET state = ? WHERE id = ? AND target_id = ?",
      [txt("rejected"), txt(inner-id), txt(a.actor)]
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
  // Every Undo deletes only rows OWNED by the actor doing the undo
  // (actor_id / follower_id = a.actor). Without that scope a peer could
  // Undo any follow/like/announce row by id — an IDOR letting one peer
  // strip another's relationships. a.actor is bound to the signing key by
  // verify-signature, so this is a true ownership check.
  val inner-type = a.object-type
  val inner-id = inner-activity-id(a.object)
  if inner-id == "" then
    Just("Undo did not reference an activity id")
  elif inner-type == "Follow" then
    exec("DELETE FROM follow WHERE id = ? AND follower_id = ?",
         [txt(inner-id), txt(a.actor)])
    Nothing
  elif inner-type == "Like" then
    exec("DELETE FROM like_ WHERE id = ? AND actor_id = ?",
         [txt(inner-id), txt(a.actor)])
    Nothing
  elif inner-type == "Announce" then
    exec("DELETE FROM announce WHERE id = ? AND actor_id = ?",
         [txt(inner-id), txt(a.actor)])
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
