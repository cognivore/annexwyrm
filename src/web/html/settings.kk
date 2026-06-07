// annexwyrm/web/html/settings — the owner's settings form. v1 carries one
// setting: the responsiveness mode (the page container's max-width).

module web/html/settings

import web/html/layout

// `current` is the stored CSS value ("860px"/"1080px"/"1440px"/"none").
pub fun render-settings-form( current : string, saved : bool,
                              max-width : string = "1080px" ) : string
  val body = ([
    "<h1>settings</h1>",
    if saved then "<p class=\"hint saved\">saved.</p>" else "",
    "<form action=\"/settings\" method=\"post\">",
    "  <fieldset>",
    "    <legend>responsiveness</legend>",
    "    <label>maximum container width:",
    "      <select name=\"width\">",
    width-options(current),
    "      </select>",
    "    </label>",
    "    <p class=\"hint\">how wide the page may grow. default 1080px; <em>unlimited</em> fills the window.</p>",
    "  </fieldset>",
    "  <button type=\"submit\">save</button>",
    "</form>"
  ]).join("\n")
  layout("settings — annexwyrm", "", "<a href=\"/\">archive</a> · settings",
    body, max-width)

fun width-options( current : string ) : string
  [("860px", "860px"),
   ("1080px", "1080px"),
   ("1440px", "1440px"),
   ("none", "unlimited")
  ].map(fn(o)
    val (v, label) = o
    val sel = if v == current then " selected" else ""
    "        <option value=\"" ++ v ++ "\"" ++ sel ++ ">" ++ label ++ "</option>"
  ).join("\n")
