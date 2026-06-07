// annexwyrm/web/html/search — search results, a single-tag listing, and the
// tag index (cloud). All three reuse the home item-row rendering so a result
// list looks exactly like the archive list.

module web/html/search

import core/url
import web/html/layout
import web/html/home

// Search results page. `q` is the raw query (echoed in the box + heading);
// `rows` are the matches (already shaped as home-rows by the handler) for the
// current page; `page`/`total`/`size` drive the page controls. The page-link
// base preserves the query: `/search?q=<encoded>&page=`.
pub fun render-search( q : string, rows : list<home-row>,
                       page : int, total : int, size : int ) : string
  val heading = if q == "" then "search"
                else "results for “" ++ esc(q) ++ "”"
  val body = ([
    "<h1>" ++ heading ++ "</h1>",
    search-box(q),
    results-or-empty(rows, "no matches."),
    pagination("/search?q=" ++ url-encode(q) ++ "&page=", page, total, size)
  ]).join("\n")
  layout("search — annexwyrm", "", "<a href=\"/\">archive</a> · search", body)

// A single tag's items, paginated. The page-link base is `/tags/<encoded>?page=`.
pub fun render-tag( tag : string, rows : list<home-row>,
                    page : int, total : int, size : int ) : string
  val body = ([
    "<h1>#" ++ esc(tag) ++ "</h1>",
    search-box(""),
    results-or-empty(rows, "no items tagged #" ++ esc(tag) ++ " yet."),
    pagination("/tags/" ++ url-encode(tag) ++ "?page=", page, total, size),
    "<p class=\"back\"><a href=\"/tags\">all tags</a></p>"
  ]).join("\n")
  layout("#" ++ tag ++ " — annexwyrm", "",
    "<a href=\"/\">archive</a> · <a href=\"/tags\">tags</a> · #" ++ esc(tag), body)

// The tag index / cloud: every tag with its item count, biggest first.
pub fun render-tags-index( pairs : list<(string,int)> ) : string
  val cloud = match pairs
    Nil -> "<p class=\"empty\">no tags yet.</p>"
    _   -> "<ul class=\"tag-cloud\">\n" ++
           pairs.map(tag-cloud-item).join("\n") ++ "\n</ul>"
  val body = ([
    "<h1>tags</h1>",
    search-box(""),
    cloud
  ]).join("\n")
  layout("tags — annexwyrm", "", "<a href=\"/\">archive</a> · tags", body)

fun tag-cloud-item( p : (string,int) ) : string
  val (tag, n) = p
  "<li><a class=\"tag\" href=\"/tags/" ++ esc(tag) ++ "\">#" ++ esc(tag) ++
    "</a> <span class=\"count\">" ++ n.show ++ "</span></li>"

fun results-or-empty( rows : list<home-row>, empty-msg : string ) : string
  match rows
    Nil -> "<p class=\"empty\">" ++ empty-msg ++ "</p>"
    _   -> render-item-list(rows)
