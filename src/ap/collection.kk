// annexwyrm/ap/collection — OrderedCollection and OrderedCollectionPage.
//
// Used for inbox, outbox, followers, following, replies, likes, shares.
// Pure: builds a JSON tree from the in-memory totals and the current
// page slice.

module ap/collection

import core/types
import core/json

// A page of items. `items` is in the order they should appear; the
// caller decides chronology.
pub value struct ap-page
  page-id    : url       // .../outbox?page=2
  part-of    : url       // .../outbox
  next       : string    // "" = no next page
  prev       : string    // "" = no prev page
  items      : list<json>
  ordered    : bool      // True for OrderedCollection, False otherwise

// The collection header — what the bare collection URL returns. Two
// references (`first`, `last`) point at the first and last page.
pub value struct ap-collection
  collection-id : url
  total-items   : int
  first         : url
  last          : url
  ordered       : bool

// ----------------------------------------------------------------------
//  Serialization
// ----------------------------------------------------------------------

pub fun ap-collection/to-json( c : ap-collection ) : json
  obj-opt([
    ("@context",   string/json(ap-context-activitystreams)),
    ("id",         string/json(c.collection-id)),
    ("type",       string/json(if c.ordered then "OrderedCollection" else "Collection")),
    ("totalItems", int/json(c.total-items)),
    ("first",      if c.first == "" then JNull else string/json(c.first)),
    ("last",       if c.last == ""  then JNull else string/json(c.last))
  ])

pub fun ap-page/to-json( p : ap-page ) : json
  val type-name = if p.ordered then "OrderedCollectionPage" else "CollectionPage"
  val items-key = if p.ordered then "orderedItems" else "items"
  obj-opt([
    ("@context",   string/json(ap-context-activitystreams)),
    ("id",         string/json(p.page-id)),
    ("type",       string/json(type-name)),
    ("partOf",     string/json(p.part-of)),
    ("prev",       if p.prev == "" then JNull else string/json(p.prev)),
    ("next",       if p.next == "" then JNull else string/json(p.next)),
    (items-key,    arr(p.items))
  ])

// ----------------------------------------------------------------------
//  Paging math
// ----------------------------------------------------------------------

// Build the page-id URL `<base>?page=<n>`.
pub fun page-id-for( base : url, n : int ) : url
  base ++ "?page=" ++ n.show

// Standard page size for the fediverse. Larger is OK for actors with
// many items but most clients cap at ~40.
pub val default-page-size : int = 20

// From total items and current page, compute prev/next page numbers.
// Pages are 1-indexed (page 1 is the most recent items).
pub fun page-numbers( total : int, page : int, size : int ) : (int,int)
  val last-page = if total == 0 then 1 else 1 + (total - 1) / size
  val prev = if page <= 1 then 0 else page - 1
  val next = if page >= last-page then 0 else page + 1
  (prev, next)
