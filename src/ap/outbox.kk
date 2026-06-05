// annexwyrm/ap/outbox — emit local activities and queue delivery.
//
// Each entry point takes a local intent (publish, follow, like, undo)
// and produces an ap-activity, persists it, and inserts delivery rows.
// Callers (web/handler/* or the CLI) just call one of these.

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
  ship-activity(build-create-activity(aid, item))

pub fun emit-update( item : annex-item )
  : <db,time,rng,log,config,div|e> ()
  val aid = mint-id("activities")
  ship-activity(build-update-activity(aid, item))

// Pure activity construction kept out of the effectful body. Returning
// a value struct from a pure function avoids the mlift-capture trigger.
fun build-create-activity( aid : url, item : annex-item ) : config ap-activity
  val followers = local-actor-url() ++ "/followers"
  create-of(aid, item.owner, item-to-ap-object(item, followers))

fun build-update-activity( aid : url, item : annex-item ) : config ap-activity
  val followers = local-actor-url() ++ "/followers"
  update-of(aid, item.owner, item-to-ap-object(item, followers))

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

// Emit a Delete for an item we're tombstoning.
pub fun emit-delete( item : annex-item )
  : <db,time,rng,log,config,div|e> ap-activity
  val now = now-iso()
  val followers = local-actor-url() ++ "/followers"
  val (to-list, cc-list) = build-addressing(ItPublic, followers, [])
  val aid = mint-id("activities")
  val act = delete-of(aid, item.owner, item.id, now, to-list, cc-list)
  record-activity(ap-activity/to-json(act), act, False)
  val inboxes = resolve-recipients(act.to, act.cc)
  info("outbox/delete", [("id", aid)])
  queue-many(aid, inboxes)
  act

// Emit a Follow targeting `target-actor`. Caller should already have
// the target's inbox cached in the `actor` table (call `fetch` first).
pub fun emit-follow( target-actor : url )
  : <db,time,rng,log,config,div|e> ap-activity
  val now = now-iso()
  val aid = mint-id("activities")
  val act = follow-of(aid, local-actor-url(), target-actor, now)
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR REPLACE INTO follow (id, follower_id, target_id, state, created_at) " ++
    "VALUES (?,?,?,?,?)",
    [txt(aid), txt(local-actor-url()), txt(target-actor),
     txt("pending"), txt(now)]
  )
  val inbox = lookup-actor-inbox(target-actor)
  if inbox == "" then
    warn("outbox/follow: target inbox unknown", [("target", target-actor)])
  else
    queue-delivery(aid, inbox)
  act

// Emit an Undo to unfollow `target-actor`.
pub fun emit-undo-follow( target-actor : url )
  : <db,time,rng,log,config,div|e> maybe<ap-activity>
  val now = now-iso()
  val rows = query(
    "SELECT id FROM follow WHERE follower_id = ? AND target_id = ?",
    [txt(local-actor-url()), txt(target-actor)]
  )
  match rows.first-text
    Nothing -> Nothing
    Just(follow-aid) ->
      val follow-act = follow-of(follow-aid, local-actor-url(), target-actor, now)
      val aid = mint-id("activities")
      val act = undo-of(aid, local-actor-url(), follow-act, now)
      record-activity(ap-activity/to-json(act), act, False)
      exec("DELETE FROM follow WHERE id = ?", [txt(follow-aid)])
      val inbox = lookup-actor-inbox(target-actor)
      if inbox != "" then queue-delivery(aid, inbox)
      Just(act)

// Emit a Like for `object-id` whose owner is `owner-actor`.
pub fun emit-like( object-id : url, owner-actor : url )
  : <db,time,rng,log,config,div|e> ap-activity
  val now = now-iso()
  val aid = mint-id("activities")
  val act = like-of(aid, local-actor-url(), object-id, owner-actor, now)
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO like_ (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(aid), txt(local-actor-url()), txt(object-id), txt(now)]
  )
  val inbox = lookup-actor-inbox(owner-actor)
  if inbox != "" then queue-delivery(aid, inbox)
  act

// Emit an Announce (boost) for `object-id`.
pub fun emit-announce( object-id : url )
  : <db,time,rng,log,config,div|e> ap-activity
  val now = now-iso()
  val aid = mint-id("activities")
  val followers = local-actor-url() ++ "/followers"
  val act = announce-of(aid, local-actor-url(), object-id, followers, now)
  record-activity(ap-activity/to-json(act), act, False)
  exec(
    "INSERT OR IGNORE INTO announce (id, actor_id, object_id, created_at) " ++
    "VALUES (?,?,?,?)",
    [txt(aid), txt(local-actor-url()), txt(object-id), txt(now)]
  )
  val inboxes = resolve-recipients(act.to, act.cc)
  queue-many(aid, inboxes)
  act
