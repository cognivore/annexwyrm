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
// `file-published` is the ONLY blob gate (the item itself is always
// public): 0 = archived (encrypted remote only, no download link, nothing
// in the AP url[]); 1 = published (also on the public remote, download URL
// minted + federated). `file-public-url` is the uc?export=download form
// (the primary url[] entry + rendered link); `file-view-url` is the
// open?id viewer mirror. Both "" while archived.
pub value struct annex-item
  id              : url
  owner           : url
  kind            : object-kind
  name            : string         // title; required for Article, optional elsewhere
  summary         : string         // optional content warning / abstract
  content         : string         // body HTML; "" for pure-file items
  media-type      : string         // for Document family; ""
  byte-size       : int            // 0 = unknown
  sha256-hex      : string         // "" = unknown
  rating          : int            // -3..3, or `rating-unrated` (99) for absent
  in-reply-to     : url            // "" for top-level items; the AP id of the parent for reviews
  file-published  : bool           // False = archived; True = public download
  file-public-url : url            // uc?export=download form; "" while archived
  file-view-url   : url            // open?id viewer mirror; "" while archived
  published-at    : iso-time
  updated-at      : iso-time
  remotes         : list<item-remote>

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

// A THREE-SLOT star bar so the magnitude reads unambiguously as "out of 3":
// |r| filled ★ then the remaining slots hollow ☆ (e.g. +2 and -2 both render
// "★★☆"). Direction is carried by colour + the word phrase, not the glyph.
// "" for unrated or out-of-range.
pub fun rating-stars3( r : int ) : string
  if r == rating-unrated || r < -3 || r > 3 then ""
  else
    val m = if r < 0 then 0 - r else r
    "★".repeat(m) ++ "☆".repeat(3 - m)

// Plain-words description of a rating on the -3..+3 scale ("" for unrated).
// This is the primary, unambiguous rating display — stars alone don't say
// "out of how many".
pub fun rating-phrase( r : int ) : string
  if r == 3 then "loved it"
  elif r == 2 then "liked it a lot"
  elif r == 1 then "liked it"
  elif r == 0 then "neutral"
  elif r == -1 then "disliked it"
  elif r == -2 then "disliked it a lot"
  elif r == -3 then "hated it"
  else ""

// Signed numeral for the rating: "+2", "0", "-3". "" for unrated.
pub fun rating-signed( r : int ) : string
  if r == rating-unrated then ""
  elif r > 0 then "+" ++ r.show
  else r.show

// True iff `i` is structurally a review of another item.
pub fun annex-item/is-review( i : annex-item ) : bool
  i.in-reply-to != ""

// Every item is always federated: a single-tenant public review site has
// no private items. (The blob — not the review — is what publish-file
// gates, via `file-published`.) Kept as a predicate so callers that asked
// "should this federate?" still read cleanly; it is now a constant True.
pub fun annex-item/is-federated( i : annex-item ) : bool
  True

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
    id              = id,
    owner           = owner,
    kind            = kind,
    name            = name,
    summary         = "",
    content         = "",
    media-type      = media-type,
    byte-size       = byte-size,
    sha256-hex      = sha256-hex,
    rating          = rating-unrated,
    in-reply-to     = "",
    file-published  = False,
    file-public-url = "",
    file-view-url   = "",
    published-at    = now,
    updated-at      = now,
    remotes         = []
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
