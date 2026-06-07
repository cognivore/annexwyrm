// annexwyrm/web/html/edit — the owner's "edit review" form.
//
// Single-tenant public review site: editing changes only the human-
// authored review metadata (title, abstract/CW, body HTML, rating, and
// the review-of target). It does NOT touch the file blob — that is the
// separate, one-way publish-file action on the item page. Submitting this
// form federates an AP `Update` to followers.
//
// The form is plain application/x-www-form-urlencoded (no file part), so
// it needs no enctype — exactly like /login. Every field is pre-filled
// with the item's current value; an empty title posts back as "" (a
// deliberate clearing), which renders as "(untitled)".

module web/html/edit

import core/types
import annex/item
import web/html/layout

pub fun render-edit-form( i : annex-item, id : string, tags : list<string> ) : string
  val body = ([
    "<h1>edit review</h1>",
    "<form action=\"/items/" ++ esc(id) ++ "/edit\" method=\"post\">",
    "  <fieldset>",
    "    <legend>the review</legend>",
    "    <label>title: <input type=\"text\" name=\"name\" value=\"" ++
      esc(i.name) ++ "\" placeholder=\"(untitled)\"></label>",
    "    <label>content warning / abstract: <textarea name=\"summary\" rows=\"2\">" ++
      esc(i.summary) ++ "</textarea></label>",
    "    <label>description / review body (Markdown — **bold**, *italic*, [links](url), lists, # headings): " ++
      "<textarea name=\"content\" rows=\"8\">" ++ esc(i.content) ++ "</textarea></label>",
    "    <label>tags (space- or comma-separated, # optional): " ++
      "<input type=\"text\" name=\"tags\" value=\"" ++ esc(tags.join(" ")) ++
      "\" placeholder=\"mtg kamigawa game-design\"></label>",
    "  </fieldset>",
    "  <fieldset>",
    "    <legend>rating &amp; review</legend>",
    "    <label>rating:",
    "      <select name=\"rating\">",
    rating-options(i.rating),
    "      </select>",
    "    </label>",
    "    <label>review of (full item URL): <input type=\"url\" name=\"in_reply_to\" value=\"" ++
      esc(i.in-reply-to) ++ "\" placeholder=\"https://server/items/abc123\"></label>",
    "  </fieldset>",
    "  <p class=\"hint\">saving federates an <strong>Update</strong> to your followers. " ++
      "the file blob is untouched — use <em>publish file</em> on the item page to change " ++
      "whether the file itself is downloadable.</p>",
    "  <button type=\"submit\">save changes</button>",
    "  <a class=\"cancel\" href=\"/items/" ++ esc(id) ++ "\">cancel</a>",
    "</form>"
  ]).join("\n")
  layout("edit — annexwyrm", "",
    "<a href=\"/items/" ++ esc(id) ++ "\">item</a> · edit", body)

// The rating <select> options, with the item's current value marked
// `selected`. Mirrors the upload form's option set; value 99 = unrated.
fun rating-options( current : int ) : string
  [(99, "unrated"),
   (3,  "loved it"),
   (2,  "liked it a lot"),
   (1,  "liked it"),
   (0,  "neutral"),
   (-1, "disliked it"),
   (-2, "disliked it a lot"),
   (-3, "hated it")
  ].map(fn(o)
    val (v, label) = o
    val sel = if v == current then " selected" else ""
    "        <option value=\"" ++ v.show ++ "\"" ++ sel ++ ">" ++ label ++ "</option>"
  ).join("\n")
