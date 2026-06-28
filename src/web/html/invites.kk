// annexwyrm/web/html/invites — the admin invite-management page.

module web/html/invites

import web/html/layout

// `base` is the instance origin (for building registration URLs). `opens` is
// the list of open invites as (token, note, expires); `used` is consumed
// invites as (token, note, used-by).
pub fun render-invites(
    base : string,
    opens : list<(string,string,string)>,
    used  : list<(string,string,string)>,
    max-width : string = "1080px"
  ) : string
  val body = ([
    "<h1>invites</h1>",
    "<p class=\"subtitle\">mint a single-use link to invite a new tenant. links expire in 14 days.</p>",
    "<form action=\"/invites\" method=\"post\">",
    "  <label>note <span class=\"hint\">(optional, e.g. who it's for)</span>:",
    "    <input type=\"text\" name=\"note\">",
    "  </label>",
    "  <button type=\"submit\">mint invite</button>",
    "</form>",
    "<h2>open invites</h2>",
    open-list(base, opens),
    "<h2>used invites</h2>",
    used-list(used)
  ]).join("\n")
  layout("invites — annexwyrm", "", "<a href=\"/\">archive</a> · <a href=\"/settings\">settings</a> · invites",
    body, max-width)

fun open-list( base : string, opens : list<(string,string,string)> ) : string
  match opens
    Nil -> "<p class=\"empty\">no open invites.</p>"
    _   ->
      "<ul class=\"invites\">\n" ++
      opens.map(fn(o)
        val (token, note, expires) = o
        val url = base ++ "/register?invite=" ++ token
        "<li><code>" ++ esc(url) ++ "</code>" ++
          (if note == "" then "" else " <span class=\"meta\">" ++ esc(note) ++ "</span>") ++
          " <span class=\"meta\">expires " ++ esc(expires) ++ "</span></li>"
      ).join("\n") ++
      "\n</ul>"

fun used-list( used : list<(string,string,string)> ) : string
  match used
    Nil -> "<p class=\"empty\">none used yet.</p>"
    _   ->
      "<ul class=\"invites used\">\n" ++
      used.map(fn(o)
        val (_token, note, used-by) = o
        "<li><span class=\"meta\">claimed by</span> " ++ esc(used-by) ++
          (if note == "" then "" else " <span class=\"meta\">" ++ esc(note) ++ "</span>") ++ "</li>"
      ).join("\n") ++
      "\n</ul>"
