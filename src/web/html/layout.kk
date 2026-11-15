// annexwyrm/web/html/layout — page chrome.
//
// Pure: every template is a `string -> … -> string` function. We embed
// JSON-LD into the head so the same URL serves humans and crawlers.

module web/html/layout

import core/types

// What every page's frame needs to know about THIS request, as opposed to
// the page's own content:
//
//   max-width — the container width ("responsiveness mode"): a CSS
//               max-width value for <body> ("860px"/"1080px"/"1440px"/
//               "none"), from the persisted `container_width` setting.
//               Emitted as a <style> AFTER the stylesheet link so it wins
//               the same-specificity body rule.
//   viewer    — the signed-in local username, or "" when anonymous. The
//               nav shows it (linking to the viewer's profile) in place of
//               the login link. It is whoever web/session resolved, so a
//               native session and a Velocity sign-in render alike.
pub value struct chrome
  max-width : string
  viewer    : string

// Anonymous, default width — for pages rendered without a request.
pub val default-chrome = Chrome("1080px", "")

// Standard `<html><head>…</head><body>…</body></html>` wrapper.
//
//   title       — appears in <title> and the top bar
//   jsonld      — optional JSON-LD payload; embedded in <script
//                 type="application/ld+json"> when non-empty
//   crumbs      — breadcrumb HTML to put in the header
//   inner       — the page body
//   chrome      — the per-request page chrome (see `chrome` above).
//                 Handlers build it with web/prefs `page-chrome(req)`.
pub fun layout(
    title     : string,
    jsonld    : string,
    crumbs    : string,
    inner     : string,
    chrome    : chrome = default-chrome
  ) : string
  ([
    "<!doctype html>",
    "<html lang=\"en\">",
    "<head>",
    "  <meta charset=\"utf-8\">",
    "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "  <title>" ++ esc(title) ++ "</title>",
    "  <link rel=\"stylesheet\" href=\"/static/style.css\">",
    "  <script src=\"/static/upload.js\" defer></script>",
    "  <style>body{max-width:" ++ esc(chrome.max-width) ++ "}</style>",
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
    viewer-link(chrome.viewer),
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

// The nav's identity slot: who you are when signed in, else the way in.
fun viewer-link( viewer : string ) : string
  if viewer == "" then "    <a href=\"/login\">login</a>"
  else "    <a href=\"/users/" ++ esc(viewer) ++ "\">" ++ esc(viewer) ++ "</a>"

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
