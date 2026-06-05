// annexwyrm/web/handler/followers — GET followers / following collections.

module web/handler/followers

import core/types
import core/json
import core/url
import effects/db
import effects/config
import ap/collection
import web/server

pub fun handle-followers( req : request, u : string )
  : <db,config,div|e> response
  if u != get-local-username() then not-found("no such user")
  else
    val actor-url = get-base-url() ++ "/users/" ++ u
    val base = actor-url ++ "/followers"
    val total = query(
      "SELECT COUNT(*) FROM follow WHERE target_id = ? AND state = 'accepted'",
      [txt(actor-url)]
    ).first-int.default(0)
    val page = parse-page(req.query)
    if page <= 0
      then ok-jsonld(json/show(coll(base, total)))
      else ok-jsonld(json/show(followers-page(base, total, page,
        "SELECT follower_id FROM follow WHERE target_id = ? AND state = 'accepted' " ++
        "ORDER BY accepted_at DESC LIMIT ? OFFSET ?",
        actor-url)))

pub fun handle-following( req : request, u : string )
  : <db,config,div|e> response
  if u != get-local-username() then not-found("no such user")
  else
    val actor-url = get-base-url() ++ "/users/" ++ u
    val base = actor-url ++ "/following"
    val total = query(
      "SELECT COUNT(*) FROM follow WHERE follower_id = ? AND state = 'accepted'",
      [txt(actor-url)]
    ).first-int.default(0)
    val page = parse-page(req.query)
    if page <= 0
      then ok-jsonld(json/show(coll(base, total)))
      else ok-jsonld(json/show(followers-page(base, total, page,
        "SELECT target_id FROM follow WHERE follower_id = ? AND state = 'accepted' " ++
        "ORDER BY accepted_at DESC LIMIT ? OFFSET ?",
        actor-url)))

fun parse-page( q : string ) : div int
  query-parse(q).filter(fn(p) p.fst == "page").head
    .map(fn(p) p.snd.parse-int.default(0)).default(0)

fun text-col-as-json( v : sql-value ) : list<json>
  match v
    SqlText(s) -> [string/json(s)]
    _          -> []

fun coll( base : url, total : int ) : div json
  val last = if total == 0 then 1 else 1 + (total - 1) / default-page-size
  ap-collection/to-json(Ap-collection(
    collection-id = base,
    total-items   = total,
    first         = page-id-for(base, 1),
    last          = page-id-for(base, last),
    ordered       = True
  ))

fun followers-page( base : url, total : int, page : int, sql : string, actor-url : url )
  : <db,div> json
  val size = default-page-size
  val offset = (page - 1) * size
  val rows = query(sql, [txt(actor-url), num(size), num(offset)])
  val items = rows.flatmap(extract-text-json)
  val (prev, next-page) = page-numbers(total, page, size)
  val next-url = if next-page == 0 then "" else page-id-for(base, next-page)
  val prev-url = if prev == 0 then "" else page-id-for(base, prev)
  val pg = Ap-page(
    page-id-for(base, page),
    base,
    next-url,
    prev-url,
    items,
    True
  )
  ap-page/to-json(pg)

fun extract-text-json( r : sql-row ) : list<json>
  text-col-as-json(r.col(0))
