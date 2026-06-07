// annexwyrm/web/html/item — item detail page.
//
// Every item is public; the page renders the full review to anyone. The
// only state that varies is the FILE BLOB: archived (a quiet "file
// archived, not published" line, plus a publish-file form for the owner)
// or published (a download link, shown to everyone).

module web/html/item

import core/types
import core/json
import core/markdown
import ap/object
import annex/item
import annex/publish
import web/html/layout

pub fun render-item-page( i : annex-item, likes : int, shares : int, is-owner : bool,
                          tags : list<string> ) : div string
  val followers = i.owner ++ "/followers"
  val obj = item-to-ap-object(i, followers, tags)
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
    body-block(i),
    tags-block(tags),
    file-state-block(i, is-owner),
    owner-actions-block(i, is-owner),
    "</article>"
  ]).join("\n")
  layout(title, jsonld, "<a href=\"/items/\">items</a> · " ++ esc(title), body)

// "review of <link>" preamble if this item references another resource. The
// href is scheme-guarded (safe-url): a non-http(s) value like javascript: is
// rendered as plain escaped text, never a clickable anchor (HTML-escaping
// alone leaves a live javascript: link).
fun review-of-block( i : annex-item ) : string
  if i.in-reply-to == "" then ""
  elif safe-url(i.in-reply-to) then
    "  <p class=\"review-of\">review of " ++
    "<a href=\"" ++ esc(i.in-reply-to) ++ "\" rel=\"nofollow\">" ++ esc(i.in-reply-to) ++ "</a></p>"
  else
    "  <p class=\"review-of\">review of " ++ esc(i.in-reply-to) ++ "</p>"

// The rating in the title line: just the plain-English phrase, coloured by
// direction (positive/negative/neutral). No stars, no numeric score.
fun rating-badge( i : annex-item ) : string
  if !i.has-rating then ""
  else
    val css = if i.rating > 0 then "positive"
              elif i.rating < 0 then "negative"
              else "neutral"
    " <span class=\"rating " ++ css ++ "\">" ++ esc(rating-phrase(i.rating)) ++ "</span>"

// The review body: Markdown-rendered content, and — when a content warning /
// abstract (summary) is set — wrapped in a <details> so the body is HIDDEN
// behind the spoiler until the reader clicks it. Without a summary the body
// renders open. (Previously the CW was an empty <details> next to an always-
// visible body, so it hid nothing.)
fun body-block( i : annex-item ) : div string
  val rendered = if i.content == "" then ""
                 else "<section class=\"content\">" ++ md-to-html(i.content) ++ "</section>"
  if i.summary == "" then rendered
  else "  <details class=\"cw\"><summary>" ++ esc(i.summary) ++ "</summary>\n" ++
       rendered ++ "\n  </details>"

// The file-state block: archived vs published.
//   * Archived (file-published = False): a quiet no-link state. The owner
//     additionally gets the publish-file action form; an anonymous visitor
//     gets only the "file archived, not published" line.
//   * Published (file-published = True): the download link, shown to all.
//     No form (one-way for v1).
fun file-state-block( i : annex-item, is-owner : bool ) : string
  val tail = i.id.split("/").reverse.head.default("")
  if !has-file(i) then ""   // a pure-text review (e.g. a book) has no file
  elif i.file-published then
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

// True iff this item actually has a file blob (vs a pure-text review). A
// file-less review has byte_size 0 and no mirror remotes.
fun has-file( i : annex-item ) : bool
  i.byte-size > 0 || i.remotes.is-cons

// Public tag chips, each linking to its /tags/<tag> listing. Shown to
// everyone (tags are public metadata). "" when the item has none.
fun tags-block( tags : list<string> ) : string
  match tags
    Nil -> ""
    _   -> "  <p class=\"tags\">" ++ tags.map(tag-chip).join(" ") ++ "</p>"

fun tag-chip( t : string ) : string
  "<a class=\"tag\" href=\"/tags/" ++ esc(t) ++ "\">#" ++ esc(t) ++ "</a>"

// Owner-only review actions (edit). Anonymous visitors see nothing — a
// review is read-only to everyone but its single local owner. The blob's
// publish-file action lives in file-state-block; this is the text edit.
fun owner-actions-block( i : annex-item, is-owner : bool ) : string
  if !is-owner then ""
  else
    val tail = i.id.split("/").reverse.head.default("")
    "  <p class=\"owner-actions\"><a class=\"edit\" href=\"/items/" ++
      esc(tail) ++ "/edit\">edit</a></p>"
