// annexwyrm/annex/publish — private ↔ public transitions and the
// pure projection of an `annex-item` onto an AP `ap-object`.
//
// "Publishing" an item means: flip the privacy to `ItPublic` (or
// `ItFollowers` if the user chose followers-only), bump `updated-at`,
// and mark its mirrors `published=True`. Callers then emit the AP
// activity through `ap/outbox`.

module annex/publish

import core/types
import ap/addressing
import ap/object
import annex/item
import annex/remote

// Turn an item into the AP object the outbox will wrap in `Create`.
// `followers-url` is the owner actor's followers collection URL.
pub fun item-to-ap-object( i : annex-item, followers-url : url ) : ap-object
  val (to, cc) = build-addressing(i.privacy, followers-url, [])
  Ap-object(
    id            = i.id,
    kind          = i.kind,
    attributed-to = i.owner,
    name          = i.name,
    summary       = i.summary,
    content       = i.content,
    media-type    = i.media-type,
    urls          = item-published-links(i),
    in-reply-to   = i.in-reply-to,
    published     = i.published-at,
    updated       = if i.updated-at == i.published-at then "" else i.updated-at,
    to            = to,
    cc            = cc,
    sensitive     = i.summary != "",
    attachment    = [],
    rating        = i.rating
  )

// ----------------------------------------------------------------------
//  Transitions
// ----------------------------------------------------------------------

// Flip an item from a non-federated state to `target-privacy` (which
// must be one of ItUnlisted, ItFollowers, ItPublic). Idempotent.
pub fun publish-item( i : annex-item, target-privacy : privacy, now : iso-time ) : annex-item
  Annex-item(
    i.id, i.owner, i.kind,
    target-privacy,
    i.name, i.summary, i.content, i.media-type,
    i.byte-size, i.sha256-hex,
    i.rating, i.in-reply-to,
    i.published-at, now,
    i.remotes.map(fn(r) Item-remote(r.kind, r.target, r.media-type, r.label,
                                    publish-remote-default(target-privacy, r), r.sort-order))
  )

// When publishing, every remote whose `kind` is `RkUrl` is published by
// default; rclone / git-annex / ipfs require the user to opt them in
// (since they may not be reachable from outside).
fun publish-remote-default( p : privacy, r : item-remote ) : bool
  if !p.federates then False
  elif r.published then True              // user already opted in
  else match r.kind
    RkUrl -> True
    _     -> False

// Reverse the publish: drop the item back to `ItPrivate` and clear all
// remotes' `published` flag. Callers should also emit a `Delete`
// activity through the outbox so federated copies tombstone.
pub fun unpublish-item( i : annex-item, now : iso-time ) : annex-item
  Annex-item(
    i.id, i.owner, i.kind,
    ItPrivate,
    i.name, i.summary, i.content, i.media-type,
    i.byte-size, i.sha256-hex,
    i.rating, i.in-reply-to,
    i.published-at, now,
    i.remotes.map(fn(r) Item-remote(r.kind, r.target, r.media-type, r.label,
                                    False, r.sort-order))
  )

// Replace the entire remote list (the UI re-posts every row each save).
pub fun set-remotes( i : annex-item, rs : list<item-remote>, now : iso-time ) : annex-item
  Annex-item(
    i.id, i.owner, i.kind, i.privacy,
    i.name, i.summary, i.content, i.media-type,
    i.byte-size, i.sha256-hex,
    i.rating, i.in-reply-to,
    i.published-at, now,
    rs
  )
