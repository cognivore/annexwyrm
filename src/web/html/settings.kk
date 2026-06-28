// annexwyrm/web/html/settings — the per-tenant settings form.
//
// Two sections: the site-wide responsiveness mode (the page container's
// max-width), and the tenant's OWN rclone backend (config + remote targets).
// Admins also get a link to the invite-management page.

module web/html/settings

import web/html/layout

// `current` is the stored width ("860px"/"1080px"/"1440px"/"none"). `saved`
// is "" / "width" / "storage" (which section was just saved). `conf`,
// `archive`, `pubrem`, `url-base` pre-fill the tenant's storage section.
// `arch-status`/`pub-status` carry the self-test verdict for the storage
// banner: "" = not tested (a plain GET), "ok" = reachable, anything else is a
// failure reason. They are LAST (after max-width) so the GET caller, which
// omits them, gets the no-banner default.
pub fun render-settings-form(
    current : string, saved : string,
    conf : string, archive : string, pubrem : string, url-base : string,
    is-admin : bool, max-width : string = "1080px",
    arch-status : string = "", pub-status : string = ""
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
    storage-status-banner(arch-status, pub-status),
    storage-form(conf, archive, pubrem, url-base)
  ]).join("\n")
  layout("settings — annexwyrm", "", "<a href=\"/\">archive</a> · settings",
    body, max-width)

// The self-test verdict, shown after a save / re-test. Empty when not tested.
// The failure reason is rclone's own stderr, so esc() it.
fun storage-status-banner( arch : string, pubr : string ) : string
  if arch == "" && pubr == "" then ""
  else ([
    "<div class=\"storage-test\">",
    "  <strong>storage self-test</strong>",
    "  <ul>",
    "    " ++ status-line("archive remote (uploads)", arch, "uploads will work"),
    "    " ++ status-line("public remote (publishing)", pubr, "publishing will work"),
    "  </ul>",
    "</div>"
  ]).join("\n")

fun status-line( label : string, status : string, ok-msg : string ) : string
  if status == "ok" then
    "<li class=\"ok\">" ++ esc(label) ++ ": reachable — " ++ esc(ok-msg) ++ " ✓</li>"
  else
    "<li class=\"fail\">" ++ esc(label) ++ ": FAILED — " ++ esc(status) ++ "</li>"

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
    "    <legend>storage backend (your rclone) " ++
      "<a class=\"help\" href=\"/help/storage\" target=\"_blank\" rel=\"noopener\">[?]</a></legend>",
    "    <p class=\"hint\">your files live on <strong>your own cloud</strong> (Google Drive, S3, …) via rclone — " ++
      "this server never stores them. paste your <code>rclone.conf</code> and name your remotes. " ++
      "<strong>your secrets (cloud token, encryption password) live inside that config</strong>; it is kept " ++
      "private (mode 0600) on the server and never shown to anyone else. other members can download your " ++
      "files (the server decrypts on the fly) but never see your config. " ++
      "new to this? read the <a href=\"/help/storage\" target=\"_blank\" rel=\"noopener\">storage setup guide</a>.</p>",
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
    "  <button type=\"submit\">save &amp; test storage</button>",
    "  <button type=\"submit\" formaction=\"/settings/storage/test\">re-test saved storage</button>",
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
