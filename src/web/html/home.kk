// annexwyrm/web/html/home — / (the public archive list).

module web/html/home

import std/core/int
import web/html/layout

// How many items appear per page in the public listings (home, search, tag).
// The handler slices the query with this; the renderer recomputes the page
// count from the same value, so the controls and the slice always agree.
pub val items-per-page : int = 50

// One row in the homepage list — built by the handler, rendered here.
// `rating` carries the unrated sentinel (99) when the item has no rating.
pub value struct home-row
  id             : string
  name           : string
  kind           : string
  rating         : int           // -3..3 or 99 = unrated
  in-reply-to    : string        // "" for top-level items
  published      : string
  file-published : bool          // True ⇒ the blob has a public download

pub fun render-home( rows : list<home-row>, instance-name : string,
                     page : int, total : int, size : int ) : string
  val body = ([
    "<h1>" ++ esc(instance-name) ++ "</h1>",
    "<p class=\"subtitle\">a federated archive — pieces dropped here are mirrored, optionally shared.</p>",
    search-box(""),
    items-list(rows),
    pagination("/?page=", page, total, size)
  ]).join("\n")
  layout(instance-name, "", "<a href=\"/\">archive</a>", body)

// Page controls beneath a listing. `base` is the href prefix up to and
// including "page=" — the caller composes any other query params first (e.g.
// search's "?q=…&page="), so the link for page N is simply `base ++ N`.
// Renders nothing when everything fits on one page. The feed is newest-first,
// so page 1 holds the newest items: "newer" steps toward page 1, "older" away.
pub fun pagination( base : string, page : int, total : int, size : int ) : string
  val pages = if total <= 0 || size <= 0 then 0 else 1 + (total - 1) / size
  if pages <= 1 then ""
  else
    val newer = if page > 1
                  then "<a class=\"step newer\" rel=\"prev\" href=\"" ++
                       esc(base ++ (page - 1).show) ++ "\">← newer</a>"
                  else "<span class=\"step newer disabled\">← newer</span>"
    val older = if page < pages
                  then "<a class=\"step older\" rel=\"next\" href=\"" ++
                       esc(base ++ (page + 1).show) ++ "\">older →</a>"
                  else "<span class=\"step older disabled\">older →</span>"
    "<nav class=\"pagination\" aria-label=\"pagination\">\n" ++
      newer ++ "\n" ++
      "<span class=\"pages\">" ++ page-windows(base, page, pages).join(" ") ++ "</span>\n" ++
      older ++ "\n" ++
    "</nav>"

// The numbered page links: page 1, a ±2 window around the current page, and
// the last page, with "…" gaps standing in for runs of skipped pages. Keeps
// the control compact no matter how many pages exist.
fun page-windows( base : string, page : int, pages : int ) : list<string>
  val lo = max(1, page - 2)
  val hi = min(pages, page + 2)
  val window = list(lo, hi).map(fn(n) page-link(base, n, page))
  val head = if lo > 1
               then [page-link(base, 1, page)] ++
                    (if lo > 2 then ["<span class=\"gap\">…</span>"] else [])
               else []
  val tail = if hi < pages
               then (if hi < pages - 1 then ["<span class=\"gap\">…</span>"] else []) ++
                    [page-link(base, pages, page)]
               else []
  head ++ window ++ tail

fun page-link( base : string, n : int, current : int ) : string
  if n == current
    then "<span class=\"page current\" aria-current=\"page\">" ++ n.show ++ "</span>"
    else "<a class=\"page\" href=\"" ++ esc(base ++ n.show) ++ "\">" ++ n.show ++ "</a>"

// A reusable search form + "browse tags" link. `q` pre-fills the box (used
// on the search results page). GET so the query lands in the URL/bookmarkable.
pub fun search-box( q : string ) : string
  ([
    "<form class=\"search\" action=\"/search\" method=\"get\" role=\"search\">",
    "  <input type=\"search\" name=\"q\" value=\"" ++ esc(q) ++
      "\" placeholder=\"search titles, reviews, tags…\" aria-label=\"search\">",
    "  <button type=\"submit\">search</button>",
    "  <a class=\"browse-tags\" href=\"/tags\">browse tags</a>",
    "</form>"
  ]).join("\n")

// The <ol> of item rows, exposed so the search + tag pages render results
// identically to the home list.
pub fun render-item-list( rows : list<home-row> ) : string
  items-list(rows)

fun items-list( rows : list<home-row> ) : string
  match rows
    Nil -> "<p class=\"empty\">nothing public yet.</p>"
    _   ->
      "<ol class=\"items\">\n" ++
      rows.map(item-row).join("\n") ++
      "\n</ol>"

fun item-row( r : home-row ) : string
  val path = "/items/" ++ id-tail(r.id)
  val rev  = if r.in-reply-to == "" then "" else " <span class=\"meta\">[review]</span>"
  val file = if r.file-published then " <span class=\"meta\">[file]</span>" else ""
  "<li class=\"item-row\">" ++
    "<span class=\"kind\">[" ++ esc(r.kind.to-lower) ++ "]</span> " ++
    row-rating(r.rating) ++
    "<a class=\"title\" href=\"" ++ esc(path) ++ "\">" ++ esc-title(r.name) ++ "</a>" ++
    rev ++ file ++
    " <span class=\"meta\">" ++ esc(r.published) ++ "</span>" ++
  "</li>"

fun row-rating( r : int ) : string
  if r == 99 || r < -3 || r > 3 then ""
  else
    val css = if r > 0 then "positive" elif r < 0 then "negative" else "neutral"
    "<span class=\"rating " ++ css ++ "\">" ++ phrase-pure(r) ++ "</span> "

// Pure helper duplicated from annex/item to avoid a dependency cycle —
// the html layer should not see the domain. Kept in sync by convention.
fun phrase-pure( r : int ) : string
  if r == 3 then "loved it"
  elif r == 2 then "liked it a lot"
  elif r == 1 then "liked it"
  elif r == 0 then "neutral"
  elif r == -1 then "disliked it"
  elif r == -2 then "disliked it a lot"
  elif r == -3 then "hated it"
  else ""

fun esc-title( s : string ) : string
  if s == "" then "(untitled)" else esc(s)

// Last path segment of a full URL.  "https://x/items/abc" → "abc".
fun id-tail( id : string ) : string
  id.split("/").reverse.head.default(id)
