// annexwyrm/web/html/actor — actor profile page.
//
// Re-uses the layout. Embeds the actor JSON-LD in the <head>.

module web/html/actor

import core/json
import ap/actor
import web/html/layout

pub value struct recent-row
  id        : string
  name      : string
  kind      : string
  published : string

pub fun render-actor-page( a : ap-actor, recents : list<recent-row> ) : div string
  val title = if a.name == "" then a.preferred-username else a.name
  val jsonld = json/show(ap-actor/to-json(a))
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
    "  <h2>recent</h2>",
    recents-block(recents),
    "</section>",
    "<section class=\"actions\">",
    "  <form action=\"/follow\" method=\"post\">",
    "    <label>follow this user from another instance: copy the URL above.</label>",
    "  </form>",
    "</section>"
  ]).join("\n")
  layout(title, jsonld, "<a href=\"/users/" ++ esc(a.preferred-username) ++ "\">" ++ esc(a.preferred-username) ++ "</a>", body)

fun recents-block( rs : list<recent-row> ) : string
  match rs
    Nil -> "<p class=\"empty\">nothing public.</p>"
    _   ->
      "<ol class=\"items\">\n" ++
      rs.map(recent-row-html).join("\n") ++
      "\n</ol>"

fun recent-row-html( r : recent-row ) : string
  val path = "/items/" ++ id-tail(r.id)
  "<li class=\"item-row\">" ++
    "<span class=\"kind\">[" ++ esc(r.kind.to-lower) ++ "]</span> " ++
    "<a href=\"" ++ esc(path) ++ "\">" ++ esc(if r.name == "" then "(untitled)" else r.name) ++ "</a>" ++
    " <span class=\"meta\">" ++ esc(r.published) ++ "</span>" ++
  "</li>"

fun id-tail( id : string ) : string
  id.split("/").reverse.head.default(id)
