// annexwyrm/ap/outbox — emit local activities and queue delivery.
//
// Each entry point takes a local intent (publish, follow, like, undo),
// builds an ap-activity, persists it, and inserts delivery rows. Every
// `emit-*` returns `()` rather than the struct (see the koka#654 note
// below). Callers (web/handler/* or the CLI) just call one of these.
//
// Multitenant: the ACTING actor is explicit, never the single configured
// owner. For item activities (Create/Update/Delete) it is `item.owner`; for
// relationship activities (Follow/Like/Announce/Undo) the caller passes the
// session actor. That actor becomes the activity's `actor`, its followers
// collection drives addressing, and `sender_id` on each delivery makes the
// worker sign with THAT actor's key. So each tenant federates as itself.

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
// Public/followers expands via the DB (the ACTING actor's followers);
// explicit actor IDs resolve via the cached actor row.
fun resolve-recipients( to : list<url>, cc : list<url>, actor : url )
  : <db|e> list<url>
  val all = to ++ cc
  val followers = actor ++ "/followers"
  val needs-followers = all.any(fn(a) a == followers || is-public-iri(a))
  val explicit = all.filter(fn(a) a != followers && !is-public-iri(a))
  val explicit-inboxes = explicit.flatmap(fn(a) [lookup-actor-inbox(a)].filter(fn(s) s != ""))
  val follower-inboxes = if needs-followers then followers-inboxes(actor) else []
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

fun queue-many( aid : url, sender : url, inboxes : list<url> ) : <db,time,div|e> ()
  queue-each(aid, sender, inboxes)

fun queue-each( aid : url, sender : url, inboxes : list<url> ) : <db,time,div|e> ()
  match inboxes
    Nil -> ()
    Cons(ib, rest) ->
      queue-delivery(aid, ib, sender)
      queue-each(aid, sender, rest)

// ----------------------------------------------------------------------
//  Public entry points
// ----------------------------------------------------------------------

// Publish (or re-publish) a federation-visible item. The item must
// already be in the desired (non-private) state on disk; we just emit
// the AP Create activity. The acting actor is `item.owner`.
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
  ship-activity(build-create-activity(aid, item, tags), item.owner)

pub fun emit-update( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val aid = mint-id("activities")
  val tags = load-item-tags(item.id)
  ship-activity(build-update-activity(aid, item, tags), item.owner)

// Pure activity construction kept out of the effectful body. Returning
// a value struct from a pure function avoids the mlift-capture trigger.
// `tags` (loaded above, from the item_tag side table) federate as the AP
// object's `tag` Hashtag array. Addressing uses the OWNER's followers.
fun build-create-activity( aid : url, item : annex-item, tags : list<string> ) : div ap-activity
  val followers = item.owner ++ "/followers"
  create-of(aid, item.owner, item-to-ap-object(item, followers, tags))

fun build-update-activity( aid : url, item : annex-item, tags : list<string> ) : div ap-activity
  val followers = item.owner ++ "/followers"
  update-of(aid, item.owner, item-to-ap-object(item, followers, tags))

// Persist + queue-out an already-built activity, sent by `sender`. The
// activity is a parameter (not a local capture); returning `()` avoids the
// value struct re-entering the caller's effect frame.
fun ship-activity( act : ap-activity, sender : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  val inboxes = resolve-recipients(act.to, act.cc, sender)
  info("outbox/publish",
    [("id", act.id), ("type", act.kind.show),
     ("recipients", inboxes.length.show)])
  queue-many(act.id, sender, inboxes)

// Emit a Delete for an item we're tombstoning. Mirrors emit-create:
// effects produce inputs, a pure builder makes the struct, ship-* runs
// the multi-effect tail. Returns () for the #654 reason above.
pub fun emit-delete( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-delete(build-delete-activity(aid, item, now), item.owner)

// Pure: addressing + struct construction. Addressing uses the owner's followers.
fun build-delete-activity( aid : url, item : annex-item, now : iso-time )
  : ap-activity
  val followers = item.owner ++ "/followers"
  val (to-list, cc-list) = build-addressing(ItPublic, followers, [])
  delete-of(aid, item.owner, item.id, now, to-list, cc-list)

// The tail differs from ship-activity only in the log label, so it gets
// its own ship-* rather than force-fitting ship-activity.
fun ship-delete( act : ap-activity, sender : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  val inboxes = resolve-recipients(act.to, act.cc, sender)
  info("outbox/delete", [("id", act.id)])
  queue-many(act.id, sender, inboxes)

// Emit a Follow from `actor` (a local tenant) targeting `target-actor`.
// Caller should already have the target's inbox cached in the `actor` table
// (call `fetch` first).
pub fun emit-follow( target-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-follow(build-follow-activity(aid, target-actor, actor, now), now, target-actor, actor)

// Pure: struct construction only.
fun build-follow-activity( aid : url, target-actor : url, actor : url, now : iso-time )
  : ap-activity
  follow-of(aid, actor, target-actor, now)

// Persist + write the follow side-table row + single-inbox queue. The
// follow row needs `now`; the inbox lookup needs `target-actor`; the sender
// is `actor` (the local follower).
fun ship-follow( act : ap-activity, now : iso-time, target-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR REPLACE INTO follow (id, follower_id, target_id, state, created_at) " ++
    "VALUES (?,?,?,?,?)",
    [txt(act.id), txt(actor), txt(target-actor),
     txt("pending"), txt(now)]
  )
  val inbox = lookup-actor-inbox(target-actor)
  if inbox == "" then
    warn("outbox/follow: target inbox unknown", [("target", target-actor)])
  else
    queue-delivery(act.id, inbox, actor)

// Emit an Undo from `actor` to unfollow `target-actor`. The lookup of the
// existing follow row stays in this wrapper; on Nothing we warn and return ().
pub fun emit-undo-follow( target-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val rows = query(
    "SELECT id FROM follow WHERE follower_id = ? AND target_id = ?",
    [txt(actor), txt(target-actor)]
  )
  match rows.first-text
    Nothing -> warn("outbox/undo-follow: no such follow", [("target", target-actor)])
    Just(follow-aid) ->
      val aid = mint-id("activities")
      ship-undo-follow(
        build-undo-follow-activity(aid, follow-aid, target-actor, actor, now),
        follow-aid, target-actor, actor)

// Pure: rebuild the original follow then wrap it in an Undo.
fun build-undo-follow-activity( aid : url, follow-aid : url, target-actor : url,
                                actor : url, now : iso-time ) : ap-activity
  val follow-act = follow-of(follow-aid, actor, target-actor, now)
  undo-of(aid, actor, follow-act, now)

// Persist + delete the follow side-table row + single-inbox queue. Needs
// `follow-aid` for the DELETE and `target-actor` for the inbox lookup.
fun ship-undo-follow( act : ap-activity, follow-aid : url, target-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec("DELETE FROM follow WHERE id = ?", [txt(follow-aid)])
  val inbox = lookup-actor-inbox(target-actor)
  if inbox != "" then queue-delivery(act.id, inbox, actor)

// Emit a Like from `actor` for `object-id` whose owner is `owner-actor`.
pub fun emit-like( object-id : url, owner-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-like(build-like-activity(aid, object-id, owner-actor, actor, now), now, owner-actor, actor)

// Pure: struct construction only.
fun build-like-activity( aid : url, object-id : url, owner-actor : url,
                         actor : url, now : iso-time ) : ap-activity
  like-of(aid, actor, object-id, owner-actor, now)

// Persist + write the like side-table row + single-inbox queue. The like
// row needs `now`; the inbox lookup needs `owner-actor`; sender is `actor`.
fun ship-like( act : ap-activity, now : iso-time, owner-actor : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO like_ (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(act.id), txt(actor), txt(act.object-id), txt(now)]
  )
  val inbox = lookup-actor-inbox(owner-actor)
  if inbox != "" then queue-delivery(act.id, inbox, actor)

// Emit an Announce (boost) from `actor` for `object-id`.
pub fun emit-announce( object-id : url, actor : url )
  : <db,time,rng,log,config,div|e> ()
  val now = now-iso()
  val aid = mint-id("activities")
  ship-announce(build-announce-activity(aid, object-id, actor, now), now, actor)

// Pure: struct construction only. Fan-out is to the actor's own followers.
fun build-announce-activity( aid : url, object-id : url, actor : url, now : iso-time )
  : ap-activity
  val followers = actor ++ "/followers"
  announce-of(aid, actor, object-id, followers, now)

// Persist + write the announce side-table row + fan-out queue. The
// announce row needs `now`; sender is `actor`.
fun ship-announce( act : ap-activity, now : iso-time, actor : url )
  : <db,time,rng,log,config,div|e> ()
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO announce (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(act.id), txt(actor), txt(act.object-id), txt(now)]
  )
  val inboxes = resolve-recipients(act.to, act.cc, actor)
  queue-many(act.id, actor, inboxes)
