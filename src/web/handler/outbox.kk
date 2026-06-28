// annexwyrm/web/handler/outbox — GET /users/<u>/outbox

module web/handler/outbox

import core/types
import core/json
import core/url
import effects/db
import effects/config
import ap/collection
import ap/persist   // local-actor-id-for
import web/server

pub fun handle-outbox( req : request, u : string )
  : <db,config,div|e> response
  val actor-url = local-actor-id-for(u)
  if actor-url == "" then not-found("no such user")
  else
    val base = actor-url ++ "/outbox"
    val total = query(
      "SELECT COUNT(*) FROM activity WHERE actor_id = ? AND inbox_remote = 0",
      [txt(actor-url)]
    ).first-int.default(0)
    val page = parse-page(req.query)
    if page <= 0 then ok-jsonld(json/show(collection-doc(base, total)))
    else ok-jsonld(json/show(page-doc(base, total, page, actor-url)))

fun parse-page( q : string ) : div int
  query-parse(q).filter(fn(p) p.fst == "page").head
    .map(fn(p) p.snd.parse-int.default(0)).default(0)

fun raw-to-json( v : sql-value ) : div list<json>
  match v
    SqlText(s) -> match json-parse(s) { Just(j) -> [j]; Nothing -> [] }
    _          -> []

fun collection-doc( base : url, total : int ) : json
  val (_, last-page) = page-numbers(total, 1, default-page-size)
  val last = if total == 0 then 1
             else 1 + (total - 1) / default-page-size
  ap-collection/to-json(Ap-collection(
    collection-id = base,
    total-items   = total,
    first         = page-id-for(base, 1),
    last          = page-id-for(base, last),
    ordered       = True
  ))

fun page-doc( base : url, total : int, page : int, actor-url : url ) : <db,div> json
  val size = default-page-size
  val offset = (page - 1) * size
  val rows = query(
    "SELECT raw FROM activity WHERE actor_id = ? AND inbox_remote = 0 " ++
    "ORDER BY received_at DESC LIMIT ? OFFSET ?",
    [txt(actor-url), num(size), num(offset)]
  )
  val items = rows.flatmap(fn(r) raw-to-json(r.col(0)))
  val (prev, next) = page-numbers(total, page, size)
  ap-page/to-json(Ap-page(
    page-id = page-id-for(base, page),
    part-of = base,
    next    = if next == 0 then "" else page-id-for(base, next),
    prev    = if prev == 0 then "" else page-id-for(base, prev),
    items   = items,
    ordered = True
  ))
