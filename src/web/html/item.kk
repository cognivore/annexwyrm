// annexwyrm/web/html/item — item detail page.
//
// Every item is public; the page renders the full review to anyone. The
// only state that varies is the FILE BLOB: archived (a quiet "file
// archived, not published" line, plus a publish-file form for the owner)
// or published (a download link, shown to everyone).

module web/html/item

import core/types
import core/json
import ap/object
import annex/item
import annex/publish
import web/html/layout

pub fun render-item-page( i : annex-item, likes : int, shares : int, is-owner : bool ) : div string
  val followers = i.owner ++ "/followers"
  val obj = item-to-ap-object(i, followers)
  val jsonld = json/show(ap-object/to-json(obj))
  val title = if i.name == "" then "(untitled)" else i.name
  val body = ([
    "<article class=\"item\">",
    review-of-block(i),
    "  <h1>" ++ esc(title) ++ rating-badge(i) ++ "</h1>",
    "  <p class=\"meta\">",
    "    <span class=\"kind\">[" ++ esc(i.kind.show.to-lower) ++ "]</span>",
    "    <span class=\"author\">by <a href=\"" ++ esc(i.owner) ++ "\">" ++ esc(i.owner) ++ "</a></span>",
    "    <span class=\"date\">" ++ esc(i.published-at) ++ "</span>",
    "    <span class=\"stats\">" ++ likes.show ++ " likes · " ++ shares.show ++ " shares</span>",
    "  </p>",
    summary-block(i),
    content-block(i),
    file-state-block(i, is-owner),
    owner-actions-block(i, is-owner),
    "</article>"
  ]).join("\n")
  layout(title, jsonld, "<a href=\"/items/\">items</a> · " ++ esc(title), body)

// "review of <link>" preamble if this item points at another item.
fun review-of-block( i : annex-item ) : string
  if i.in-reply-to == "" then ""
  else "  <p class=\"review-of\">review of " ++
       "<a href=\"" ++ esc(i.in-reply-to) ++ "\">" ++ esc(i.in-reply-to) ++ "</a></p>"

// The bracketed rating + star glyphs that go in the title line.
fun rating-badge( i : annex-item ) : string
  if !i.has-rating then ""
  else
    val css = if i.rating > 0 then "positive"
              elif i.rating < 0 then "negative"
              else "neutral"
    " <span class=\"rating " ++ css ++ "\">" ++ rating-show(i.rating) ++
    " <span class=\"stars\">" ++ rating-stars(i.rating) ++ "</span></span>"

fun summary-block( i : annex-item ) : string
  if i.summary == "" then ""
  else "  <details class=\"cw\"><summary>" ++ esc(i.summary) ++
       "</summary><p></p></details>"

fun content-block( i : annex-item ) : string
  if i.content == "" then ""
  else "  <section class=\"content\">" ++ i.content ++ "</section>"

// The file-state block: archived vs published.
//   * Archived (file-published = False): a quiet no-link state. The owner
//     additionally gets the publish-file action form; an anonymous visitor
//     gets only the "file archived, not published" line.
//   * Published (file-published = True): the download link, shown to all.
//     No form (one-way for v1).
fun file-state-block( i : annex-item, is-owner : bool ) : string
  val tail = i.id.split("/").reverse.head.default("")
  if i.file-published then
    val view = if i.file-view-url == "" || i.file-view-url == i.file-public-url then ""
               else " <a class=\"view\" href=\"" ++ esc(i.file-view-url) ++
                    "\" rel=\"nofollow\">view</a>"
    "  <p class=\"file-state published\">" ++
      "<a class=\"download\" href=\"" ++ esc(i.file-public-url) ++
      "\" rel=\"nofollow\">download</a>" ++ view ++ "</p>"
  else
    val action =
      if !is-owner then ""
      else "\n  <form action=\"/items/" ++ esc(tail) ++ "/publish-file\" method=\"post\">\n" ++
           "    <button type=\"submit\">publish file</button>\n" ++
           "  </form>"
    "  <p class=\"file-state archived\">file archived, not published</p>" ++ action

// Owner-only review actions (edit). Anonymous visitors see nothing — a
// review is read-only to everyone but its single local owner. The blob's
// publish-file action lives in file-state-block; this is the text edit.
fun owner-actions-block( i : annex-item, is-owner : bool ) : string
  if !is-owner then ""
  else
    val tail = i.id.split("/").reverse.head.default("")
    "  <p class=\"owner-actions\"><a class=\"edit\" href=\"/items/" ++
      esc(tail) ++ "/edit\">edit</a></p>"
