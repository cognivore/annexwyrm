// annexwyrm/web/html/edit — the owner's "edit review" form.
//
// The edit page is the single place to manage an item: its human-authored
// review metadata (title, spoiler-free review, in-depth Markdown review,
// rating, the reference URL) AND its file blob. From here the owner can
// attach a file to a file-less review, replace an existing blob, and flip
// the file between archived (encrypted remote only, no download) and
// published (public download). Submitting federates an AP `Update`.
//
// The form is multipart/form-data (it can carry a file part). Every text
// field is pre-filled; the `publicly downloadable` checkbox is pre-checked
// to reflect the file's CURRENT publication state. Sections mirror the
// upload form: "media" then "reference & rating" (URL first, tags on
// their own row), one full-width field per row.

module web/html/edit

import core/types
import annex/item
import web/html/layout

pub fun render-edit-form( i : annex-item, id : string, tags : list<string>,
                          max-width : string = "1080px" ) : string
  val body = ([
    "<h1>edit review</h1>",
    "<form action=\"/items/" ++ esc(id) ++ "/edit\" method=\"post\" enctype=\"multipart/form-data\">",
    "  <fieldset>",
    "    <legend>media</legend>",
    "    <p class=\"hint\">" ++ file-state-line(i) ++ "</p>",
    "    <label>" ++ (if has-file(i) then "replace file" else "attach a file") ++
      " (optional): <input type=\"file\" name=\"file\"></label>",
    "    <label><input type=\"checkbox\" name=\"publish_file\" value=\"1\"" ++
      (if i.file-published then " checked" else "") ++
      "> file is publicly downloadable</label>",
    "    <p class=\"hint\">ticked = the blob is copied to the public remote, a download " ++
      "link is minted, and it federates. unticked = archived only (encrypted remote, no " ++
      "public download). un-ticking a published file <strong>deletes</strong> it from the " ++
      "public remote — the download stops. the encrypted archive copy always stays.</p>",
    "    <label>title: <input type=\"text\" name=\"name\" required value=\"" ++
      esc(i.name) ++ "\" placeholder=\"the work's title\"></label>",
    "    <label>spoiler-free review: <textarea name=\"summary\" rows=\"2\">" ++
      esc(i.summary) ++ "</textarea></label>",
    "    <label>in-depth review (markdown): <textarea name=\"content\" rows=\"8\">" ++
      esc(i.content) ++ "</textarea></label>",
    "  </fieldset>",
    "  <fieldset>",
    "    <legend>reference &amp; rating</legend>",
    "    <label>reference URL: <input type=\"url\" name=\"in_reply_to\" value=\"" ++
      esc(i.in-reply-to) ++ "\" placeholder=\"https://bookwyrm.social/book/12345 — the work this reviews\"></label>",
    "    <label>rating:",
    "      <select name=\"rating\">",
    rating-options(i.rating),
    "      </select>",
    "    </label>",
    "    <label>tags (space- or comma-separated, # optional): " ++
      "<input type=\"text\" name=\"tags\" value=\"" ++ esc(tags.join(" ")) ++
      "\" placeholder=\"mtg kamigawa game-design\"></label>",
    "  </fieldset>",
    "  <p class=\"hint\">saving federates an <strong>Update</strong> to your followers.</p>",
    "  <button type=\"submit\">save changes</button>",
    "  <a class=\"cancel\" href=\"/items/" ++ esc(id) ++ "\">cancel</a>",
    "</form>"
  ]).join("\n")
  layout("edit — annexwyrm", "",
    "<a href=\"/items/" ++ esc(id) ++ "\">item</a> · edit", body, max-width)

// True iff this item actually has a file blob (vs a pure-text review).
fun has-file( i : annex-item ) : bool
  i.byte-size > 0 || i.remotes.is-cons

// One line describing the file's current state, shown above the controls.
fun file-state-line( i : annex-item ) : string
  if !has-file(i) then "currently: <em>no file</em> — this is a text-only review."
  elif i.file-published then "currently: <em>published</em> — the file is publicly downloadable."
  else "currently: <em>archived</em> — encrypted remote only, no public download."

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
