// annexwyrm/web/html/actor — actor profile page.
//
// The actor metadata (id/inbox/outbox/followers, embedded JSON-LD) plus that
// user's FULL archive, paginated and rendered with the same rich rows as the
// home feed (reusing web/html/home). The per-row "by <user>" attribution is
// suppressed here — it's redundant on a single user's page.

module web/html/actor

import core/json
import ap/actor
import web/html/layout
import web/html/home   // home-row, render-item-list, pagination

pub fun render-actor-page( a : ap-actor, rows : list<home-row>,
                           page : int, total : int, size : int,
                           max-width : string = "1080px" ) : div string
  val title = if a.name == "" then a.preferred-username else a.name
  val jsonld = json/show(ap-actor/to-json(a))
  val base = "/users/" ++ a.preferred-username ++ "?page="
  val plural = if total == 1 then "" else "s"
  val body = ([
    "<section class=\"actor\">",
    "  <h1>" ++ esc(title) ++
       " <small class=\"handle\">@" ++ esc(a.preferred-username) ++ "</small></h1>",
    "  <p class=\"summary\">" ++ esc(a.summary) ++ "</p>",
    "  <dl class=\"actor-meta\">",
    "    <dt>id</dt><dd>" ++ "<a href=\"" ++ esc(a.id) ++ "\">" ++ esc(a.id) ++ "</a></dd>",
    "    <dt>inbox</dt><dd>" ++ esc(a.inbox) ++ "</dd>",
    "    <dt>outbox</dt><dd>" ++ "<a href=\"" ++ esc(a.outbox) ++ "\">" ++ esc(a.outbox) ++ "</a></dd>",
    "    <dt>followers</dt><dd>" ++ "<a href=\"" ++ esc(a.followers) ++ "\">" ++ esc(a.followers) ++ "</a></dd>",
    "  </dl>",
    "</section>",
    "<section>",
    "  <h2>archive <small class=\"count\">" ++ total.show ++ " item" ++ plural ++ "</small></h2>",
    render-item-list(rows),
    pagination(base, page, total, size),
    "</section>",
    "<section class=\"actions\">",
    "  <p class=\"hint\">follow this user from another instance: copy the URL above.</p>",
    "</section>"
  ]).join("\n")
  layout(title, jsonld, "<a href=\"/users/" ++ esc(a.preferred-username) ++ "\">" ++ esc(a.preferred-username) ++ "</a>", body, max-width)
