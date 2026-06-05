// annexwyrm/web/html/login — login form.

module web/html/login

import web/html/layout

pub fun render-login-form( err : string ) : string
  val body = ([
    "<h1>log in</h1>",
    err-block(err),
    "<form action=\"/login\" method=\"post\">",
    "  <label>username: <input type=\"text\" name=\"username\" required autocomplete=\"username\"></label>",
    "  <label>password: <input type=\"password\" name=\"password\" required autocomplete=\"current-password\"></label>",
    "  <button type=\"submit\">log in</button>",
    "</form>"
  ]).join("\n")
  layout("log in — annexwyrm", "", "<a href=\"/login\">login</a>", body)

fun err-block( err : string ) : string
  if err == "" then "" else "<p class=\"err\">" ++ esc(err) ++ "</p>"
