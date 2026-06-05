// annexwyrm/web/html/item — item detail page.

module web/html/item

import core/types
import core/json
import ap/object
import annex/item
import annex/publish
import web/html/layout

pub fun render-item-page( i : annex-item, likes : int, shares : int ) : div string
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
    "    <span class=\"privacy\">" ++ esc(i.privacy.show) ++ "</span>",
    "    <span class=\"author\">by <a href=\"" ++ esc(i.owner) ++ "\">" ++ esc(i.owner) ++ "</a></span>",
    "    <span class=\"date\">" ++ esc(i.published-at) ++ "</span>",
    "    <span class=\"stats\">" ++ likes.show ++ " likes · " ++ shares.show ++ " shares</span>",
    "  </p>",
    summary-block(i),
    content-block(i),
    remotes-block(i),
    actions-block(i),
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

fun remotes-block( i : annex-item ) : string
  match i.remotes
    Nil -> ""
    _ ->
      "<section class=\"remotes\">\n" ++
      "  <h2>mirrors</h2>\n" ++
      "  <ul>\n" ++
      i.remotes.map(remote-li).join("\n") ++
      "\n  </ul>\n" ++
      "</section>"

fun remote-li( r : item-remote ) : string
  val flag = if r.published then " published" else ""
  val label = if r.label == "" then r.target else r.label
  "    <li class=\"remote " ++ esc(r.kind.show) ++ esc(flag) ++ "\">" ++
    "<span class=\"rkind\">" ++ esc(r.kind.show) ++ "</span> " ++
    "<a href=\"" ++ esc(r.target) ++ "\">" ++ esc(label) ++ "</a>" ++
  "</li>"

fun actions-block( i : annex-item ) : string
  val tail = i.id.split("/").reverse.head.default("")
  match i.privacy
    ItPrivate ->
      "<section class=\"actions\">\n" ++
      "  <form action=\"/items/" ++ esc(tail) ++ "/publish\" method=\"post\">\n" ++
      "    <button type=\"submit\">publish</button>\n" ++
      "  </form>\n" ++
      "</section>"
    _ ->
      "<section class=\"actions\">\n" ++
      "  <form action=\"/items/" ++ esc(tail) ++ "/unpublish\" method=\"post\">\n" ++
      "    <button type=\"submit\">unpublish</button>\n" ++
      "  </form>\n" ++
      "</section>"
