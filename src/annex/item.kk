// annexwyrm/annex/item — the local archive entry.
//
// One row in the `item` table, in memory. The mirrors live in a
// secondary list; the AP `url` array is built from the subset whose
// `published` flag is set.

module annex/item

import core/types

// A single mirror / backup of an item's bytes. Multiple rows per item,
// arbitrary order; UI sorts by `sort-order`.
pub value struct item-remote
  kind       : remote-kind
  target     : string          // rclone "remote:path", URL, magnet, …
  media-type : string          // override; "" = inherit
  label      : string          // human label
  published  : bool            // True ⇒ included in AP `url` array
  sort-order : int

// One archive entry.
//
// `rating` is the user's score for this item on a -3..+3 scale; we use
// 99 as an in-band "unrated" sentinel so the value type stays scalar
// (no maybe<int> threading through positional constructors).
//
// `in-reply-to` is the AP `inReplyTo` URL; non-empty marks this item as
// a review of another item (which may live on another server).
pub value struct annex-item
  id           : url
  owner        : url
  kind         : object-kind
  privacy      : privacy
  name         : string         // title; required for Article, optional elsewhere
  summary      : string         // optional content warning / abstract
  content      : string         // body HTML; "" for pure-file items
  media-type   : string         // for Document family; ""
  byte-size    : int            // 0 = unknown
  sha256-hex   : string         // "" = unknown
  rating       : int            // -3..3, or `rating-unrated` (99) for absent
  in-reply-to  : url            // "" for top-level items; the AP id of the parent for reviews
  published-at : iso-time
  updated-at   : iso-time
  remotes      : list<item-remote>

// Sentinel meaning "no rating".  -3..+3 is the actual scale.
pub val rating-unrated : int = 99

// True iff the item has a non-sentinel rating in range.
pub fun annex-item/has-rating( i : annex-item ) : bool
  i.rating != rating-unrated && i.rating >= -3 && i.rating <= 3

// Clamp an arbitrary integer to the legal rating set (-3..3) OR return
// the unrated sentinel for values outside that band.
pub fun clamp-rating( n : int ) : int
  if n >= -3 && n <= 3 then n else rating-unrated

// "[+3]", "[ 0]", "[-2]", or "" if absent. Used by the HTML renderer
// and the AP `summary` line.
pub fun rating-show( r : int ) : string
  if r == rating-unrated then ""
  elif r > 0 then "[+" ++ r.show ++ "]"
  elif r == 0 then "[ 0]"
  else "[" ++ r.show ++ "]"

// Pure-text "stars" form: N filled stars for positive, N hollow for
// negative, "" for zero or unrated. Used in HTML next to `rating-show`.
pub fun rating-stars( r : int ) : string
  if r == rating-unrated then ""
  elif r > 0 then "★".repeat(r)
  elif r < 0 then "☆".repeat(0 - r)
  else ""

// True iff `i` is structurally a review of another item.
pub fun annex-item/is-review( i : annex-item ) : bool
  i.in-reply-to != ""

// True iff the item is currently federated (publishable / discoverable).
pub fun annex-item/is-federated( i : annex-item ) : bool
  i.privacy.federates

// The mirrors that should appear in the AP `url` field.
pub fun annex-item/published-remotes( i : annex-item ) : list<item-remote>
  i.remotes.filter(fn(r) r.published).sort-on-order

fun sort-on-order( xs : list<item-remote> ) : list<item-remote>
  xs   // SQL provides the order; we don't re-sort here

// Smart constructor for a freshly-ingested item with no remotes yet.
pub fun fresh-item(
    id           : url,
    owner        : url,
    kind         : object-kind,
    name         : string,
    media-type   : string,
    byte-size    : int,
    sha256-hex   : string,
    now          : iso-time
  ) : annex-item
  Annex-item(
    id           = id,
    owner        = owner,
    kind         = kind,
    privacy      = ItPrivate,
    name         = name,
    summary      = "",
    content      = "",
    media-type   = media-type,
    byte-size    = byte-size,
    sha256-hex   = sha256-hex,
    rating       = rating-unrated,
    in-reply-to  = "",
    published-at = now,
    updated-at   = now,
    remotes      = []
  )

// Smart constructor for a fresh remote row attached to an item.
pub fun fresh-remote(
    kind       : remote-kind,
    target     : string,
    media-type : string = "",
    label      : string = "",
    sort-order : int = 0
  ) : item-remote
  Item-remote(
    kind       = kind,
    target     = target,
    media-type = media-type,
    label      = label,
    published  = False,
    sort-order = sort-order
  )
