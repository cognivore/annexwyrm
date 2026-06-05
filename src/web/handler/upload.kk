// annexwyrm/web/handler/upload — GET/POST /upload.
//
// GET shows the form. POST accepts a multipart/form-data body, ingests
// the file into the staging area, records the item + the remotes the
// user attached via the [+] button (one or more `remote_target` fields),
// and redirects to the new item page.

module web/handler/upload

import core/types
import core/json
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/store
import effects/crypto
import annex/item
import web/server
import web/multipart
import web/html/upload
import web/handler/item

pub fun handle-upload-form( req : request ) : <db,config|e> response
  if !is-owner-session(req) then forbidden("login required")
  else ok-html(render-upload-form())

pub fun handle-upload-post( req : request )
  : <db,time,rng,log,config,store,crypto,div|e> response
  if !is-owner-session(req) then forbidden("login required")
  else
    val ct = req.header("content-type").default("")
    match parse-multipart(ct, req.body)
      Nothing -> bad-request("expected multipart/form-data")
      Just(parts) ->
        val files-list = files(parts)
        match files-list
          Nil -> bad-request("no file uploaded")
          Cons(f, _) ->
            val name = parts.field("name").default(f.filename)
            val summary = parts.field("summary").default("")
            val content = parts.field("content").default("")
            val privacy = privacy/parse(parts.field("privacy").default("private"))
                            .default(ItPrivate)
            val rating = clamp-rating(parts.field("rating").default("99").parse-int.default(99))
            val in-reply-to = parts.field("in_reply_to").default("")
            val remote-targets = parts.all-fields("remote_target")
            val remote-kinds   = parts.all-fields("remote_kind")
            val remote-labels  = parts.all-fields("remote_label")
            ingest(f, name, summary, content, privacy, rating, in-reply-to,
                   remote-targets, remote-kinds, remote-labels)

fun ingest(
    f : mpart,
    name : string,
    summary : string,
    content : string,
    privacy : privacy,
    rating : int,
    in-reply-to : string,
    targets : list<string>,
    kinds   : list<string>,
    labels  : list<string>
  ) : <db,time,rng,log,config,store,crypto,div|e> response
  val now = now-iso()
  val owner = get-base-url() ++ "/users/" ++ get-local-username()
  val slug = rand-hex(12)
  val id = get-base-url() ++ "/items/" ++ slug
  val media = if f.media-type == "" then "application/octet-stream" else f.media-type
  val sha = b64-encode(sha256(f.body))
  val byte-size = f.body.count

  // Stage the bytes in our default local remote. (The actual remote
  // for `Document` files is the item.remotes list; this is just our
  // copy for later re-publishing.)
  blob-put(Blob-loc("local", slug), f.body)

  val mt-kind = guess-kind(media)
  val rs = build-remotes(targets, kinds, labels)
  val it1 = Annex-item(
    id, owner, mt-kind, privacy,
    name, summary, content, media,
    byte-size, sha,
    rating, in-reply-to,
    now, now,
    rs
  )
  save-item(it1)
  // Push the bytes to every writable remote (rclone, git-annex). Plain
  // URL mirrors stay where the user pointed us; IPFS would require the
  // caller to have already pinned the CID.
  rs.foreach(fn(r) push-to-remote(r, f.body))
  info("upload/done", [("id", id), ("size", byte-size.show), ("remotes", rs.length.show)])
  see-other("/items/" ++ slug)

// If `r` is a writable remote, copy the bytes there; otherwise no-op.
fun push-to-remote( r : item-remote, body : string ) : <store,log|e> ()
  match r.kind
    RkRclone   ->
      info("upload/push", [("kind", "rclone"), ("target", r.target)])
      blob-put(Blob-loc("", r.target), body)
    RkGitAnnex ->
      info("upload/push", [("kind", "git-annex"), ("target", r.target)])
      blob-put(Blob-loc("git-annex", r.target), body)
    _ -> ()

fun guess-kind( media : string ) : object-kind
  match media-type/parse(media)
    Just(mt) -> object-kind/from-media(mt)
    Nothing  -> OkDocument

// Zip the three parallel lists into item-remote records. Missing fields
// default to RkUrl / "" / sort_order=index.
fun build-remotes( targets : list<string>, kinds : list<string>, labels : list<string> )
  : list<item-remote>
  zip3-with-index(targets, kinds, labels, 0)

fun zip3-with-index( ts : list<string>, ks : list<string>, ls : list<string>, i : int )
  : list<item-remote>
  match ts
    Nil -> []
    Cons(t, ts-rest) ->
      val k = ks.head.default("url")
      val l = ls.head.default("")
      val rk = remote-kind/parse(k).default(RkUrl)
      val r = Item-remote(rk, t, "", l, False, i)
      Cons(r, zip3-with-index(ts-rest, ks.tail-or-empty, ls.tail-or-empty, i + 1))

fun tail-or-empty( xs : list<a> ) : list<a>
  match xs
    Nil -> []
    Cons(_, rest) -> rest
