// annexwyrm/ap/outbox — emit local activities and queue delivery.
//
// Each entry point takes a local intent (publish, follow, like, undo),
// builds an ap-activity, persists it, and inserts delivery rows. Every
// `emit-*` returns `()` rather than the struct (see the koka#654 note
// below). Callers (web/handler/* or the CLI) just call one of these.

module ap/outbox

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import ap/activity
import ap/object
import ap/persist
import ap/addressing
import annex/item
import annex/publish

// ----------------------------------------------------------------------
//  Helpers
// ----------------------------------------------------------------------

// Map a list of addresses to the set of inbox URLs we should deliver to.
// Public/followers expands via the DB; explicit actor IDs resolve via
// the cached actor row.
fun resolve-recipients( to : list<url>, cc : list<url> )
  : <db,config|e> list<url>
  val all = to ++ cc
  val followers = local-actor-url() ++ "/followers"
  val needs-followers = all.any(fn(a) a == followers || is-public-iri(a))
  val explicit = all.filter(fn(a) a != followers && !is-public-iri(a))
  val explicit-inboxes = explicit.flatmap(fn(a) [lookup-actor-inbox(a)].filter(fn(s) s != ""))
  val follower-inboxes = if needs-followers then followers-inboxes(local-actor-url()) else []
  dedup(explicit-inboxes ++ follower-inboxes)

fun dedup( xs : list<string> ) : list<string>
  dedup-go(xs, [])

fun dedup-go( xs : list<string>, seen : list<string> ) : list<string>
  match xs
    Nil -> seen.reverse
    Cons(x, rest) ->
      if seen.any(fn(s) s == x)
        then dedup-go(rest, seen)
        else dedup-go(rest, Cons(x, seen))

fun queue-many( aid : url, inboxes : list<url> ) : <db,time,config,div|e> ()
  queue-each(aid, inboxes)

fun queue-each( aid : url, inboxes : list<url> ) : <db,time,config,div|e> ()
  match inboxes
    Nil -> ()
    Cons(ib, rest) ->
      queue-delivery(aid, ib)
      queue-each(aid, rest)

// ----------------------------------------------------------------------
//  Public entry points
// ----------------------------------------------------------------------

// Publish (or re-publish) a federation-visible item. The item must
// already be in the desired (non-private) state on disk; we just emit
// the AP Create activity.
//
// `emit-*` returns `()`, not the activity record itself. Returning the
// just-built `ap-activity` value struct from an effectful function makes
// Koka 3.2.3 mlift the body with the struct in the closure, and koka-
// lang/koka#654 then panics. The other `ap/inbox` shaped functions
// (e.g. `auto-accept-follow`) work because they also return `()` —
// follow that pattern.
pub fun emit-create( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val aid = mint-id("activities")
  val tags = load-item-tags(item.id)
  ship-activity(build-create-activity(aid, item, tags))

pub fun emit-update( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val aid = mint-id("activities")
  val tags = load-item-tags(item.id)
  ship-activity(build-update-activity(aid, item, tags))

// Pure activity construction kept out of the effectful body. Returning
// a value struct from a pure function avoids the mlift-capture trigger.
// `tags` (loaded above, from the item_tag side table) federate as the AP
// object's `tag` Hashtag array.
fun build-create-activity( aid : url, item : annex-item, tags : list<string> ) : <config,div> ap-activity
  val followers = local-actor-url() ++ "/followers"
  create-of(aid, item.owner, item-to-ap-object(item, followers, tags))

fun build-update-activity( aid : url, item : annex-item, tags : list<string> ) : <config,div> ap-activity
  val followers = local-actor-url() ++ "/followers"
  update-of(aid, item.owner, item-to-ap-object(item, followers, tags))

// Persist + queue-out an already-built activity. The activity is a
// parameter (not a local capture); returning `()` avoids the value
// struct re-entering the caller's effect frame.
fun ship-activity( act : ap-activity )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  val inboxes = resolve-recipients(act.to, act.cc)
  info("outbox/publish",
    [("id", act.id), ("type", act.kind.show),
     ("recipients", inboxes.length.show)])
  queue-many(act.id, inboxes)

// Emit a Delete for an item we're tombstoning. Mirrors emit-create:
// effects produce inputs, a pure builder makes the struct, ship-* runs
// the multi-effect tail. Returns () for the #654 reason above.
pub fun emit-delete( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-delete(build-delete-activity(aid, item, now))

// Pure: addressing + struct construction, config effect only.
fun build-delete-activity( aid : url, item : annex-item, now : iso-time )
  : config ap-activity
  val followers = local-actor-url() ++ "/followers"
  val (to-list, cc-list) = build-addressing(ItPublic, followers, [])
  delete-of(aid, item.owner, item.id, now, to-list, cc-list)

// The tail differs from ship-activity only in the log label, so it gets
// its own ship-* rather than force-fitting ship-activity.
fun ship-delete( act : ap-activity )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  val inboxes = resolve-recipients(act.to, act.cc)
  info("outbox/delete", [("id", act.id)])
  queue-many(act.id, inboxes)

// Emit a Follow targeting `target-actor`. Caller should already have
// the target's inbox cached in the `actor` table (call `fetch` first).
pub fun emit-follow( target-actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-follow(build-follow-activity(aid, target-actor, now), now, target-actor)

// Pure: struct construction only.
fun build-follow-activity( aid : url, target-actor : url, now : iso-time )
  : config ap-activity
  follow-of(aid, local-actor-url(), target-actor, now)

// Persist + write the follow side-table row + single-inbox queue. The
// follow row needs `now`; the inbox lookup needs `target-actor`.
fun ship-follow( act : ap-activity, now : iso-time, target-actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR REPLACE INTO follow (id, follower_id, target_id, state, created_at) " ++
    "VALUES (?,?,?,?,?)",
    [txt(act.id), txt(local-actor-url()), txt(target-actor),
     txt("pending"), txt(now)]
  )
  val inbox = lookup-actor-inbox(target-actor)
  if inbox == "" then
    warn("outbox/follow: target inbox unknown", [("target", target-actor)])
  else
    queue-delivery(act.id, inbox)

// Emit an Undo to unfollow `target-actor`. The lookup of the existing
// follow row stays in this wrapper; on Nothing we warn and return ().
pub fun emit-undo-follow( target-actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val rows = query(
    "SELECT id FROM follow WHERE follower_id = ? AND target_id = ?",
    [txt(local-actor-url()), txt(target-actor)]
  )
  match rows.first-text
    Nothing -> warn("outbox/undo-follow: no such follow", [("target", target-actor)])
    Just(follow-aid) ->
      val aid = mint-id("activities")
      ship-undo-follow(
        build-undo-follow-activity(aid, follow-aid, target-actor, now),
        follow-aid, target-actor)

// Pure: rebuild the original follow then wrap it in an Undo.
fun build-undo-follow-activity( aid : url, follow-aid : url, target-actor : url,
                                now : iso-time ) : config ap-activity
  val follow-act = follow-of(follow-aid, local-actor-url(), target-actor, now)
  undo-of(aid, local-actor-url(), follow-act, now)

// Persist + delete the follow side-table row + single-inbox queue. Needs
// `follow-aid` for the DELETE and `target-actor` for the inbox lookup.
fun ship-undo-follow( act : ap-activity, follow-aid : url, target-actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec("DELETE FROM follow WHERE id = ?", [txt(follow-aid)])
  val inbox = lookup-actor-inbox(target-actor)
  if inbox != "" then queue-delivery(act.id, inbox)

// Emit a Like for `object-id` whose owner is `owner-actor`.
pub fun emit-like( object-id : url, owner-actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-like(build-like-activity(aid, object-id, owner-actor, now), now, owner-actor)

// Pure: struct construction only.
fun build-like-activity( aid : url, object-id : url, owner-actor : url,
                         now : iso-time ) : config ap-activity
  like-of(aid, local-actor-url(), object-id, owner-actor, now)

// Persist + write the like side-table row + single-inbox queue. The like
// row needs `now`; the inbox lookup needs `owner-actor`.
fun ship-like( act : ap-activity, now : iso-time, owner-actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO like_ (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(act.id), txt(local-actor-url()), txt(act.object-id), txt(now)]
  )
  val inbox = lookup-actor-inbox(owner-actor)
  if inbox != "" then queue-delivery(act.id, inbox)

// Emit an Announce (boost) for `object-id`.
pub fun emit-announce( object-id : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-announce(build-announce-activity(aid, object-id, now), now)

// Pure: struct construction only.
fun build-announce-activity( aid : url, object-id : url, now : iso-time )
  : config ap-activity
  val followers = local-actor-url() ++ "/followers"
  announce-of(aid, local-actor-url(), object-id, followers, now)

// Persist + write the announce side-table row + fan-out queue. The
// announce row needs `now`.
fun ship-announce( act : ap-activity, now : iso-time )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO announce (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(act.id), txt(local-actor-url()), txt(act.object-id), txt(now)]
  )
  val inboxes = resolve-recipients(act.to, act.cc)
  queue-many(act.id, inboxes)
