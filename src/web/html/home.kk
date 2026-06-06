// annexwyrm/web/html/home — / (the public archive list).

module web/html/home

import web/html/layout

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

pub fun render-home( rows : list<home-row>, instance-name : string ) : string
  val body = ([
    "<h1>" ++ esc(instance-name) ++ "</h1>",
    "<p class=\"subtitle\">a federated archive — pieces dropped here are mirrored, optionally shared.</p>",
    search-box(""),
    items-list(rows)
  ]).join("\n")
  layout(instance-name, "", "<a href=\"/\">archive</a>", body)

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
