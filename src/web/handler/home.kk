// annexwyrm/web/handler/home — GET /
//
// Browser: the public archive index (with [view] links to items).
// Federator: redirect to the actor URL (same content, just JSON-LD).

module web/handler/home

import core/types
import effects/db
import effects/config
import web/server
import web/html/home

pub fun handle-home( req : request ) : <db,config|e> response
  if prefers-jsonld(req) then
    see-other(get-base-url() ++ "/users/" ++ get-local-username())
  else
    // Every item is public; the home list shows them all. The only blob
    // gate (file_published) is surfaced as a small [file] marker, never as
    // a privacy word.
    val rows = query(
      "SELECT id, name, object_type, " ++
      "COALESCE(rating,99), COALESCE(in_reply_to,''), published_at, " ++
      "COALESCE(file_published,0) " ++
      "FROM item " ++
      "ORDER BY published_at DESC LIMIT 50",
      []
    )
    val items = rows.map(fn(r) Home-row(
      id             = text(r.col(0)),
      name           = text(r.col(1)),
      kind           = text(r.col(2)),
      rating         = intval(r.col(3)),
      in-reply-to    = text(r.col(4)),
      published      = text(r.col(5)),
      file-published = intval(r.col(6)) != 0
    ))
    ok-html(render-home(items, get-instance-name()))

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun intval( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(99); _ -> 99 }
