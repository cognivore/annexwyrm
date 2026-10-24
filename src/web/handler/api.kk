// annexwyrm/web/handler/api — the JSON API under /api.
//
// The same reviews and files the forms manage, for scripts, agents and
// other apps — with the SAME judgements: every mutation goes through the
// one persist-and-federate tail the forms use (ingest-parts,
// apply-file-change), so an API edit emits exactly the Update a form edit
// does, an API upload archives before anything is written, and the owner
// gate is the owner gate.
//
//   POST   /api/login            {"username","password"} → {"token","actor","expires_at"}
//   DELETE /api/session          (bearer) revoke this token
//   GET    /api/me               (bearer) who the token is
//   GET    /api/items[?limit&page]        every item, newest first (items are public)
//   GET    /api/items/<id>                one item
//   POST   /api/items            (bearer) JSON review, or multipart with a file
//   PATCH  /api/items/<id>       (bearer, owner) any subset of fields — field by field
//   PUT    /api/items/<id>/file  (bearer, owner) raw bytes; X-Filename; ?publish=1
//
// Authentication is `Authorization: Bearer <token>`; a token is a session
// row, minted by /api/login without rotating the browser's. A bearer client
// is never handed a cookie.
//
// Field names are the form's: name, summary, content, rating, in_reply_to,
// tags, file_published. A PATCH is parsed into a typed patch before any
// effect runs: an unknown field, a rating outside -3..3, a non-string tag
// or an empty patch is a 400 that changed nothing. JSON `null` clears a
// nullable field (rating, in_reply_to); an absent field is kept.

module web/handler/api

import core/types
import core/url
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/store
import effects/crypto
import annex/item
import annex/publish
import annex/storage
import ap/persist          // save-item-tags, load-item-tags
import web/session
import web/server
import web/multipart
import web/handler/item    // load-item, id-tail, apply-file-change, ship-edited-item
import web/handler/upload  // ingest-parts, ingest-textonly, ingest, ingest-outcome
import web/handler/login   // verify-login, mint-session

// ----------------------------------------------------------------------
//  Responses
// ----------------------------------------------------------------------

fun status-text( status : int ) : string
  if status == 200 then "OK"
  elif status == 201 then "Created"
  elif status == 204 then "No Content"
  elif status == 400 then "Bad Request"
  elif status == 401 then "Unauthorized"
  elif status == 403 then "Forbidden"
  elif status == 404 then "Not Found"
  elif status == 415 then "Unsupported Media Type"
  else "Internal Server Error"

fun json-response( status : int, j : json ) : div response
  Response(status, status-text(status),
           [("Content-Type", "application/json; charset=utf-8")],
           json/show(j) ++ "\n")

fun api-error( status : int, msg : string ) : div response
  json-response(status, obj([("error", JString(msg))]))

fun no-content() : response
  Response(204, "No Content", [], "")

// ----------------------------------------------------------------------
//  The item as JSON
// ----------------------------------------------------------------------

fun nullable( s : string ) : json
  if s == "" then JNull else JString(s)

pub fun item-json( it : annex-item, tags : list<string> ) : json
  val item-id : string = it.id
  obj([
    ("id", JString(item-id)),
    ("slug", JString(id-tail(item-id))),
    ("owner", JString(it.owner)),
    ("type", JString(it.kind.show)),
    ("name", JString(it.name)),
    ("summary", JString(it.summary)),
    ("content", JString(it.content)),
    ("rating", if it.has-rating then JNumber(it.rating.show) else JNull),
    ("in_reply_to", nullable(it.in-reply-to)),
    ("tags", JArray(tags.map(fn(t) JString(t)))),
    ("media_type", nullable(it.media-type)),
    ("byte_size", JNumber(it.byte-size.show)),
    ("sha256", nullable(it.sha256-hex)),
    ("file_published", JBool(it.file-published)),
    ("file_public_url", nullable(it.file-public-url)),
    ("file_view_url", nullable(it.file-view-url)),
    ("published_at", JString(it.published-at)),
    ("updated_at", JString(it.updated-at))
  ])

// Load + encode one item, or a 404.
fun item-response( status : int, id : url ) : <db,div|e> response
  match load-item(id)
    Nothing -> api-error(404, "no such item")
    Just(it) ->
      val tags = load-item-tags(id)
      json-response(status, item-json(it, tags))

fun full-id( slug : string ) : config url
  get-base-url() ++ "/items/" ++ slug

// ----------------------------------------------------------------------
//  Auth
// ----------------------------------------------------------------------

// POST /api/login — JSON credentials → a bearer token. Does NOT rotate the
// actor's other sessions: a script logging in must not log the browser out.
pub fun handle-api-login( req : request )
  : <db,time,rng,log,config,crypto,div|e> response
  match json-parse(req.body)
    Nothing -> api-error(400, "body must be a JSON object with username and password")
    Just(j) ->
      val username = j.get-string("username")
      val password = j.get-string("password")
      match verify-login(username, password)
        Nothing ->
          info("api/login-refused", [("username", username)])
          api-error(401, "invalid credentials")
        Just(aid) ->
          val (tok, expiry) = mint-session(aid, False)
          info("api/login", [("actor", aid)])
          json-response(200, obj([
            ("token", JString(tok)),
            ("actor", JString(aid)),
            ("expires_at", JString(expiry))
          ]))

// DELETE /api/session — revoke the presented token.
pub fun handle-api-logout( req : request ) : <db,div|e> response
  val tok = session-token(req)
  if tok == "" then api-error(401, "login required")
  else
    val _ = exec("DELETE FROM session WHERE token = ?", [txt(tok)])
    no-content()

// GET /api/me — the actor behind the token.
pub fun handle-api-me( req : request ) : <db,div|e> response
  match current-session(req)
    Nothing -> api-error(401, "login required")
    Just(s) -> json-response(200, obj([
      ("actor", JString(s.actor-id)),
      ("username", JString(s.username)),
      ("is_admin", JBool(s.is-admin))
    ]))

// ----------------------------------------------------------------------
//  Read
// ----------------------------------------------------------------------

pub fun handle-api-list( req : request ) : <db,config,div|e> response
  val params = query-parse(req.query)
  val limit0 = field-of(params, "limit").parse-int.default(50)
  val limit = if limit0 < 1 then 1 elif limit0 > 200 then 200 else limit0
  val page0 = field-of(params, "page").parse-int.default(1)
  val page = if page0 < 1 then 1 else page0
  val total = query("SELECT COUNT(*) FROM item", []).first-int.default(0)
  val rows = query(
    "SELECT id FROM item ORDER BY published_at DESC, id LIMIT ? OFFSET ?",
    [num(limit), num((page - 1) * limit)]
  )
  val ids = rows.map(fn(r) text(r.col(0)))
  json-response(200, obj([
    ("items", JArray(items-json(ids))),
    ("total", JNumber(total.show)),
    ("page", JNumber(page.show)),
    ("limit", JNumber(limit.show))
  ]))

// One item at a time, by explicit recursion — no closure ever holds an
// annex-item (koka#654).
fun items-json( ids : list<string> ) : <db,div|e> list<json>
  match ids
    Nil -> Nil
    Cons(id, rest) ->
      match load-item(id)
        Nothing -> items-json(rest)
        Just(it) ->
          val tags = load-item-tags(id)
          Cons(item-json(it, tags), items-json(rest))

pub fun handle-api-get( req : request, slug : string ) : <db,config,div|e> response
  item-response(200, full-id(slug))

// ----------------------------------------------------------------------
//  Create
// ----------------------------------------------------------------------

// POST /api/items. JSON ⇒ a file-less review; multipart/form-data ⇒ the
// /upload form's fields plus an optional file part.
pub fun handle-api-create( req : request )
  : <db,time,rng,log,config,store,crypto,div|e> response
  val owner = session-actor(req)
  if owner == "" then api-error(401, "login required")
  else
    val ct = req.header("content-type").default("")
    if ct.starts-with("multipart/form-data").is-just then
      match parse-multipart(ct, req.body)
        Nothing -> api-error(400, "unparseable multipart body")
        Just(parts) -> ingest-response(ingest-parts(parts, owner))
    elif ct.starts-with("application/json").is-just || ct == "" then
      match json-parse(req.body)
        Nothing -> api-error(400, "body must be a JSON object")
        Just(j) ->
          match parse-patch(j)
            Left(why) -> api-error(400, why)
            Right(p) ->
              match p.file-published
                Set(_) -> api-error(400, "file_published needs a file: upload one with PUT /api/items/<id>/file")
                Keep ->
                  val slug = ingest-textonly(
                    p.name.or(""), p.summary.or(""), p.content.or(""),
                    p.rating.or(rating-unrated), p.in-reply-to.or(""),
                    p.tags.or([]), owner)
                  item-response(201, full-id(slug))
    else api-error(415, "send application/json or multipart/form-data")

fun ingest-response( outcome : ingest-outcome ) : <db,config,div|e> response
  match outcome
    Ingested(slug) -> item-response(201, full-id(slug))
    NoStorage -> api-error(500, "configure your storage in settings before uploading files")
    ArchivePutFailed(remote) -> api-error(500, "archive put failed: blob could not be written to " ++ remote)
    PublicPutFailed(remote) -> api-error(500, "public put failed: blob could not be published to " ++ remote)

// ----------------------------------------------------------------------
//  Edit, field by field
// ----------------------------------------------------------------------

// A field in a patch: absent (keep) or present (set, possibly to its
// cleared value).
pub type edit<a>
  Keep
  Set( v : a )

fun edit/or( e : edit<a>, dflt : a ) : a
  match e
    Keep   -> dflt
    Set(v) -> v

pub struct item-patch
  name           : edit<string>
  summary        : edit<string>
  content        : edit<string>
  rating         : edit<int>            // Set(rating-unrated) for null
  in-reply-to    : edit<string>         // Set("") for null
  tags           : edit<list<string>>   // already normalised
  file-published : edit<bool>

fun empty-patch() : item-patch
  Item-patch(Keep, Keep, Keep, Keep, Keep, Keep, Keep)

// `is-keep` is the constructor predicate Koka derives for `Keep`.
fun patch-is-empty( p : item-patch ) : bool
  p.name.is-keep && p.summary.is-keep && p.content.is-keep && p.rating.is-keep &&
    p.in-reply-to.is-keep && p.tags.is-keep && p.file-published.is-keep

// Parse a JSON object into a patch, rejecting anything the item model
// cannot hold. Every field is checked before any effect runs.
fun parse-patch( j : json ) : either<string, item-patch>
  match j.object
    Nothing -> Left("body must be a JSON object")
    Just(fields) -> parse-fields(fields, empty-patch())

fun parse-fields( fields : list<(string,json)>, acc : item-patch ) : either<string, item-patch>
  match fields
    Nil -> if patch-is-empty(acc) then Left("nothing to change: no known field present") else Right(acc)
    Cons((key, v), rest) ->
      if key == "name" then
        match v.string
          Just(s) -> parse-fields(rest, acc(name = Set(s)))
          Nothing -> Left("name must be a string")
      elif key == "summary" then
        match v.string
          Just(s) -> parse-fields(rest, acc(summary = Set(s)))
          Nothing -> Left("summary must be a string")
      elif key == "content" then
        match v.string
          Just(s) -> parse-fields(rest, acc(content = Set(s)))
          Nothing -> Left("content must be a string")
      elif key == "rating" then
        match v
          JNull -> parse-fields(rest, acc(rating = Set(rating-unrated)))
          _ -> match v.int
            Just(n) -> if n >= -3 && n <= 3 then parse-fields(rest, acc(rating = Set(n)))
                       else Left("rating must be an integer from -3 to 3, or null")
            Nothing -> Left("rating must be an integer from -3 to 3, or null")
      elif key == "in_reply_to" then
        match v
          JNull -> parse-fields(rest, acc(in-reply-to = Set("")))
          _ -> match v.string
            Just(s) -> parse-fields(rest, acc(in-reply-to = Set(s.trim)))
            Nothing -> Left("in_reply_to must be a URL string, or null")
      elif key == "tags" then
        match v.array
          Nothing -> Left("tags must be an array of strings")
          Just(xs) ->
            match all-strings(xs)
              Nothing -> Left("tags must be an array of strings")
              Just(ss) -> parse-fields(rest, acc(tags = Set(parse-tags(ss.join(" ")))))
      elif key == "file_published" then
        match v.bool
          Just(b) -> parse-fields(rest, acc(file-published = Set(b)))
          Nothing -> Left("file_published must be true or false")
      else Left("unknown field: " ++ key)

fun all-strings( xs : list<json> ) : maybe<list<string>>
  match xs
    Nil -> Just(Nil)
    Cons(x, rest) ->
      match x.string
        Nothing -> Nothing
        Just(s) -> match all-strings(rest)
          Nothing -> Nothing
          Just(ss) -> Just(Cons(s, ss))

// PATCH /api/items/<id>
pub fun handle-api-patch( req : request, slug : string )
  : <db,time,rng,log,config,store,crypto,div|e> response
  val id = full-id(slug)
  match load-item(id)
    Nothing -> api-error(404, "no such item")
    Just(it) ->
      val who = session-actor(req)
      if who == "" then api-error(401, "login required")
      elif who != it.owner then api-error(403, "not your item")
      else match json-parse(req.body)
        Nothing -> api-error(400, "body must be a JSON object")
        Just(j) -> match parse-patch(j)
          Left(why) -> api-error(400, why)
          Right(p) ->
            val has-blob = it.byte-size > 0 || it.remotes.is-cons
            match p.file-published
              Set(_) | !has-blob -> api-error(400, "file_published needs a file: upload one with PUT /api/items/<id>/file")
              _ ->
                // Everything effectful is read BEFORE the edited value is
                // built, and the built value goes straight into the tail
                // (koka#654: never an effect between building and consuming
                // an annex-item).
                val current-tags = load-item-tags(id)
                val ts-opt = load-tenant-store(it.owner)
                val now = now-iso()
                val want-public = p.file-published.or(it.file-published)
                val tags = p.tags.or(current-tags)
                val base = edit-item-fields(it,
                  p.name.or(it.name), p.summary.or(it.summary), p.content.or(it.content),
                  p.rating.or(it.rating), p.in-reply-to.or(it.in-reply-to), now)
                if apply-file-change(base, it.file-published, Nothing, want-public, slug, now, tags, ts-opt) then
                  info("api/item-edited", [("id", id)])
                  item-response(200, id)
                else api-error(500, "file operation failed; the review was not changed")

// ----------------------------------------------------------------------
//  Upload bytes to an existing item
// ----------------------------------------------------------------------

// PUT /api/items/<id>/file — attach or replace the blob with the raw
// request body. Archived first (verified), published only if ?publish=1.
pub fun handle-api-put-file( req : request, slug : string )
  : <db,time,rng,log,config,store,crypto,div|e> response
  val id = full-id(slug)
  match load-item(id)
    Nothing -> api-error(404, "no such item")
    Just(it) ->
      val who = session-actor(req)
      if who == "" then api-error(401, "login required")
      elif who != it.owner then api-error(403, "not your item")
      elif req.body == "" then api-error(400, "empty body: send the file's bytes")
      else
        val media = req.header("content-type").default("application/octet-stream").split(";").head.default("").trim
        val filename = req.header("x-filename").default(slug)
        val want-public = field-of(query-parse(req.query), "publish") == "1"
        val part = Mpart("file", filename, media, req.body)
        val current-tags = load-item-tags(id)
        val ts-opt = load-tenant-store(it.owner)
        val now = now-iso()
        val base = edit-item-fields(it, it.name, it.summary, it.content, it.rating, it.in-reply-to, now)
        if apply-file-change(base, it.file-published, Just(part), want-public, slug, now, current-tags, ts-opt) then
          info("api/file-put", [("id", id), ("publish", if want-public then "1" else "0")])
          item-response(200, id)
        else api-error(500, "file operation failed; the item was not changed")

// ----------------------------------------------------------------------
//  Small helpers
// ----------------------------------------------------------------------

fun field-of( fs : list<(string,string)>, k : string ) : string
  match fs
    Nil -> ""
    Cons((k0,v), rest) -> if k0 == k then v else field-of(rest, k)

fun text( v : sql-value ) : string
  match v { SqlText(s) -> s; _ -> "" }
