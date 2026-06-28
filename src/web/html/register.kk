// annexwyrm/web/html/register — the invite registration form.

module web/html/register

import web/html/layout

// `token` is the (validated) invite token, carried as a hidden field.
// `error` is a validation message to show ("" = none).
pub fun render-register-form( token : string, error : string, max-width : string = "1080px" ) : string
  val body = ([
    "<h1>register</h1>",
    "<p class=\"subtitle\">you've been invited to this annexwyrm. pick a handle and a password.</p>",
    if error == "" then "" else "<p class=\"hint error\">" ++ esc(error) ++ "</p>",
    "<form action=\"/register\" method=\"post\">",
    "  <input type=\"hidden\" name=\"invite\" value=\"" ++ esc(token) ++ "\">",
    "  <label>username <span class=\"hint\">(a–z, 0–9, '-', '_'; up to 32)</span>:",
    "    <input type=\"text\" name=\"username\" autocomplete=\"username\" required>",
    "  </label>",
    "  <label>display name <span class=\"hint\">(optional)</span>:",
    "    <input type=\"text\" name=\"name\">",
    "  </label>",
    "  <label>password <span class=\"hint\">(at least 8 characters)</span>:",
    "    <input type=\"password\" name=\"password\" autocomplete=\"new-password\" required>",
    "  </label>",
    "  <label>confirm password:",
    "    <input type=\"password\" name=\"confirm\" autocomplete=\"new-password\" required>",
    "  </label>",
    "  <button type=\"submit\">create account</button>",
    "</form>",
    "<p class=\"hint\">after registering you'll set up your storage backend (rclone) in settings.</p>"
  ]).join("\n")
  layout("register — annexwyrm", "", "<a href=\"/\">archive</a> · register", body, max-width)
