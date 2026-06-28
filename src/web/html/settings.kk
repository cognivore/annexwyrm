// annexwyrm/web/html/settings — the per-tenant settings form.
//
// Two sections: the site-wide responsiveness mode (the page container's
// max-width), and the tenant's OWN rclone backend (config + remote targets).
// Admins also get a link to the invite-management page.

module web/html/settings

import web/html/layout

// `current` is the stored width ("860px"/"1080px"/"1440px"/"none"). `saved`
// is "" / "width" / "storage" (which section was just saved). `conf`,
// `archive`, `public`, `url-base` pre-fill the tenant's storage section.
pub fun render-settings-form(
    current : string, saved : string,
    conf : string, archive : string, pubrem : string, url-base : string,
    is-admin : bool, max-width : string = "1080px"
  ) : string
  val body = ([
    "<h1>settings</h1>",
    saved-hint(saved),
    admin-links(is-admin),
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
    "  <button type=\"submit\">save width</button>",
    "</form>",
    storage-form(conf, archive, pubrem, url-base)
  ]).join("\n")
  layout("settings — annexwyrm", "", "<a href=\"/\">archive</a> · settings",
    body, max-width)

fun saved-hint( saved : string ) : string
  if saved == "width" then "<p class=\"hint saved\">width saved.</p>"
  elif saved == "storage" then "<p class=\"hint saved\">storage saved.</p>"
  else ""

fun admin-links( is-admin : bool ) : string
  if !is-admin then ""
  else "<p class=\"hint\">admin: <a href=\"/invites\">manage invites</a> — invite a new tenant.</p>"

// The tenant's own rclone backend. This is what makes a tenant's uploads land
// on ITS cloud; a file upload is refused until archive + public are set.
fun storage-form( conf : string, archive : string, pubrem : string, url-base : string ) : string
  ([
    "<form action=\"/settings/storage\" method=\"post\">",
    "  <fieldset>",
    "    <legend>storage backend (your rclone)</legend>",
    "    <p class=\"hint\">your files are stored on YOUR cloud via rclone. paste your",
    "      <code>rclone.conf</code> below and name the remotes. these are private to you;",
    "      other tenants can view your files (the daemon decrypts through this config) but",
    "      never see the config itself. leave the config blank to use the server's ambient rclone.</p>",
    "    <label>rclone.conf:",
    "      <textarea name=\"rclone_conf\" rows=\"10\" spellcheck=\"false\" " ++
      "placeholder=\"paste your rclone.conf — [archive-crypt], [public], ...\">" ++
      esc(conf) ++ "</textarea>",
    "    </label>",
    "    <label>archive remote (encrypted; required):",
    "      <input type=\"text\" name=\"archive_remote\" value=\"" ++ esc(archive) ++
      "\" placeholder=\"archive-crypt:annexwyrm\" autocomplete=\"off\">",
    "    </label>",
    "    <label>public remote (downloads; required):",
    "      <input type=\"text\" name=\"public_remote\" value=\"" ++ esc(pubrem) ++
      "\" placeholder=\"public:annexwyrm-public\" autocomplete=\"off\">",
    "    </label>",
    "    <label>public URL base (optional; for CDN/S3 public buckets):",
    "      <input type=\"text\" name=\"public_url_base\" value=\"" ++ esc(url-base) ++
      "\" placeholder=\"https://cdn.example.com/files\" autocomplete=\"off\">",
    "    </label>",
    "  </fieldset>",
    "  <button type=\"submit\">save storage</button>",
    "</form>"
  ]).join("\n")

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
