// annexwyrm/web/html/layout — page chrome.
//
// Pure: every template is a `string -> … -> string` function. We embed
// JSON-LD into the head so the same URL serves humans and crawlers.

module web/html/layout

import core/types

// Standard `<html><head>…</head><body>…</body></html>` wrapper.
//
//   title       — appears in <title> and the top bar
//   jsonld      — optional JSON-LD payload; embedded in <script
//                 type="application/ld+json"> when non-empty
//   crumbs      — breadcrumb HTML to put in the header
//   inner       — the page body
//   max-width   — the container width ("responsiveness mode"): a CSS
//                 max-width value for <body> ("860px"/"1080px"/"1440px"/
//                 "none"). Handlers read the persisted setting (the
//                 `setting` table, key container_width) and thread it in;
//                 the default matches the site default of 1080px. Emitted
//                 as a <style> AFTER the stylesheet link so it wins the
//                 same-specificity body rule.
pub fun layout(
    title     : string,
    jsonld    : string,
    crumbs    : string,
    inner     : string,
    max-width : string = "1080px"
  ) : string
  ([
    "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "  <meta charset=\"utf-8\">",
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "  <title>" ++ esc(title) ++ "</title>",
    "  <link rel=\"stylesheet\" href=\"/static/style.css\">",
    "  <style>body{max-width:" ++ esc(max-width) ++ "}</style>",
    embed-jsonld(jsonld),
    "</head>",
    "<body>",
    "<header class=\"top\">",
    "  <span class=\"brand\"><a href=\"/\">annexwyrm</a></span>",
    "  <span class=\"crumbs\">" ++ crumbs ++ "</span>",
    "  <span class=\"nav\">",
    "    <a href=\"/\">archive</a> ·",
    "    <a href=\"/upload\">upload</a> ·",
    "    <a href=\"/settings\">settings</a> ·",
    "    <a href=\"/login\">login</a>",
    "  </span>",
    "</header>",
    "<main>",
    inner,
    "</main>",
    "<footer>",
    "  <small>annexwyrm · federated git-annex · <a href=\"/.well-known/nodeinfo\">nodeinfo</a></small>",
    "</footer>",
    "</body>",
    "</html>"
  ]).join("\n")

fun embed-jsonld( s : string ) : string
  if s == "" then ""
  else "  <script type=\"application/ld+json\">" ++ js-escape(s) ++ "</script>"

// HTML attribute / text escaping. Conservative: covers the five
// XML-named entities plus the curly braces (defence against accidental
// template injection if a string is ever used inside `style=` or JS).
pub fun esc( s : string ) : string
  s.list.map(esc-char).join("")

fun esc-char( c : char ) : string
  if c == '<' then "&lt;"
  elif c == '>' then "&gt;"
  elif c == '&' then "&amp;"
  elif c == '"' then "&quot;"
  elif c == '\'' then "&#39;"
  else c.string

// Escaping inside a `<script type="application/ld+json">` block — we
// only need to defend against `</` ending the script element.
pub fun js-escape( s : string ) : string
  s.replace-all("</", "<\\/")
