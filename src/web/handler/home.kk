// annexwyrm/web/handler/home — GET /
//
// Browser: the public archive index (with [view] links to items).
// Federator: redirect to the actor URL (same content, just JSON-LD).

module web/handler/home

import core/types
import core/url
import effects/db
import effects/config
import web/prefs
import web/server
import web/html/home

pub fun handle-home( req : request ) : <db,config,div|e> response
  if prefers-jsonld(req) then
    see-other(get-base-url() ++ "/users/" ++ get-local-username())
  else
    // Every item is public; the home list shows them all, newest first, one
    // page (items-per-page) at a time. The only blob gate (file_published) is
    // surfaced as a small [file] marker, never as a privacy word.
    val size = items-per-page
    val total = query("SELECT COUNT(*) FROM item", []).first-int.default(0)
    val pages = if total <= 0 then 1 else 1 + (total - 1) / size
    // Clamp ?page= into [1, pages] so a hand-typed / stale cursor can never
    // produce a negative offset or an empty out-of-range page.
    val req-page = page-param(req.query)
    val page = if req-page < 1 then 1 elif req-page > pages then pages else req-page
    val offset = (page - 1) * size
    val rows = query(
      "SELECT i.id, i.name, i.object_type, " ++
      "COALESCE(i.rating,99), COALESCE(i.in_reply_to,''), i.published_at, " ++
      "COALESCE(i.file_published,0), COALESCE(a.username,'') " ++
      "FROM item i LEFT JOIN actor a ON a.id = i.owner_id " ++
      "ORDER BY i.published_at DESC LIMIT ? OFFSET ?",
      [num(size), num(offset)]
    )
    val items = rows.map(fn(r) Home-row(
      id             = text(r.col(0)),
      name           = text(r.col(1)),
      kind           = text(r.col(2)),
      rating         = intval(r.col(3)),
      in-reply-to    = text(r.col(4)),
      published      = text(r.col(5)),
      file-published = intval(r.col(6)) != 0,
      owner          = text(r.col(7))
    ))
    ok-html(render-home(items, get-instance-name(), page, total, size, get-page-width()))

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun intval( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(99); _ -> 99 }
