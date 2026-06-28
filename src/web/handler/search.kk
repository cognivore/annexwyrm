// annexwyrm/web/handler/search — GET /search, /tags, /tags/<tag>.
//
// All public (every item is public). Search is a portable LIKE scan over
// title/summary/content + tags (no FTS dependency, so it works on the
// stock SQLite that ships on the prod box and in nixpkgs). The query is
// ALWAYS a bound parameter — never interpolated — so there is no SQL
// injection surface; the only effect of `%`/`_` inside `q` is a broader
// LIKE match.

module web/handler/search

import core/types
import core/url
import effects/db
import effects/config
import annex/item
import web/prefs
import web/server
import web/html/home
import web/html/search

// GET /search?q=…&page=N
pub fun handle-search( req : request ) : <db,config,div|e> response
  val q = form-lookup(query-parse(req.query), "q").default("").trim
  if q == "" then ok-html(render-search("", [], 1, 0, items-per-page, get-page-width()))
  else
    val size = items-per-page
    val total = count-search(q)
    val page = clamp-page(page-param(req.query), total, size)
    ok-html(render-search(q, search-items(q, page, size), page, total, size, get-page-width()))

// GET /tags/<tag>?page=N
pub fun handle-tag( req : request, seg : string ) : <db,config,div|e> response
  // Normalise the path segment exactly as stored tags are normalised, so
  // /tags/MTG and /tags/%23mtg both resolve to the canonical "mtg". A segment
  // that normalises to nothing (e.g. all punctuation) is a real 404, not a
  // bogus query on the raw segment.
  match parse-tags(seg).head
    Nothing  -> not-found("no such tag")
    Just(tag) ->
      val size = items-per-page
      val total = count-tag(tag)
      val page = clamp-page(page-param(req.query), total, size)
      ok-html(render-tag(tag, items-by-tag(tag, page, size), page, total, size, get-page-width()))

// Clamp a requested 1-based page into [1, pages] for `total` rows at `size`
// per page, so a hand-typed cursor can't produce a negative offset or an
// out-of-range empty page.
fun clamp-page( req-page : int, total : int, size : int ) : int
  val pages = if total <= 0 then 1 else 1 + (total - 1) / size
  if req-page < 1 then 1 elif req-page > pages then pages else req-page

// GET /tags
pub fun handle-tags-index( req : request ) : <db,config|e> response
  ok-html(render-tags-index(all-tags(), get-page-width()))

// ----------------------------------------------------------------------
//  Queries
// ----------------------------------------------------------------------

fun search-items( q : string, page : int, size : int ) : db list<home-row>
  val like = "%" ++ q ++ "%"
  val like-lc = "%" ++ q.to-lower ++ "%"
  val offset = (page - 1) * size
  query(
    "SELECT DISTINCT i.id, i.name, i.object_type, COALESCE(i.rating,99), " ++
    "COALESCE(i.in_reply_to,''), i.published_at, COALESCE(i.file_published,0), " ++
    "COALESCE(a.username,'') " ++
    "FROM item i LEFT JOIN item_tag t ON t.item_id = i.id " ++
    "LEFT JOIN actor a ON a.id = i.owner_id " ++
    "WHERE i.name LIKE ? OR i.summary LIKE ? OR i.content LIKE ? OR t.tag LIKE ? " ++
    "ORDER BY i.published_at DESC LIMIT ? OFFSET ?",
    [txt(like), txt(like), txt(like), txt(like-lc), num(size), num(offset)]
  ).map(to-home-row)

// Total distinct matches for the search query (drives the page count).
fun count-search( q : string ) : db int
  val like = "%" ++ q ++ "%"
  val like-lc = "%" ++ q.to-lower ++ "%"
  query(
    "SELECT COUNT(DISTINCT i.id) " ++
    "FROM item i LEFT JOIN item_tag t ON t.item_id = i.id " ++
    "WHERE i.name LIKE ? OR i.summary LIKE ? OR i.content LIKE ? OR t.tag LIKE ?",
    [txt(like), txt(like), txt(like), txt(like-lc)]
  ).first-int.default(0)

fun items-by-tag( tag : string, page : int, size : int ) : db list<home-row>
  val offset = (page - 1) * size
  query(
    "SELECT i.id, i.name, i.object_type, COALESCE(i.rating,99), " ++
    "COALESCE(i.in_reply_to,''), i.published_at, COALESCE(i.file_published,0), " ++
    "COALESCE(a.username,'') " ++
    "FROM item i JOIN item_tag t ON t.item_id = i.id " ++
    "LEFT JOIN actor a ON a.id = i.owner_id " ++
    "WHERE t.tag = ? ORDER BY i.published_at DESC LIMIT ? OFFSET ?",
    [txt(tag), num(size), num(offset)]
  ).map(to-home-row)

// Total items carrying this tag (drives the page count).
fun count-tag( tag : string ) : db int
  query(
    "SELECT COUNT(*) FROM item i JOIN item_tag t ON t.item_id = i.id WHERE t.tag = ?",
    [txt(tag)]
  ).first-int.default(0)

fun all-tags() : db list<(string,int)>
  query(
    "SELECT tag, COUNT(*) FROM item_tag GROUP BY tag " ++
    "ORDER BY COUNT(*) DESC, tag LIMIT 200",
    []
  ).map(fn(r) (text(r.col(0)), intval(r.col(1))))

fun to-home-row( r : sql-row ) : home-row
  Home-row(
    id             = text(r.col(0)),
    name           = text(r.col(1)),
    kind           = text(r.col(2)),
    rating         = intval(r.col(3)),
    in-reply-to    = text(r.col(4)),
    published      = text(r.col(5)),
    file-published = intval(r.col(6)) != 0,
    owner          = text(r.col(7))
  )

// ----------------------------------------------------------------------
//  Small helpers
// ----------------------------------------------------------------------

fun form-lookup( fs : list<(string,string)>, k : string ) : maybe<string>
  match fs
    Nil -> Nothing
    Cons((k0,v), rest) -> if k0 == k then Just(v) else form-lookup(rest, k)

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }

fun intval( v : sql-value ) : int
  match v { SqlInt(n) -> n; SqlText(s) -> s.parse-int.default(99); _ -> 99 }
