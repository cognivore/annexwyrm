// annexwyrm/web/handler/upload — GET/POST /upload.
//
// GET shows the form. POST accepts a multipart/form-data body and ingests
// the review. In the single-tenant model every upload:
//   * ALWAYS copies the blob to the encrypted archive remote (mandatory:
//     if that put cannot be verified the whole upload fails 5xx, with no
//     item row and no Create — a review whose file evaporated is worse
//     than a failed upload);
//   * ALWAYS saves the item and emits a Create — the review federates
//     immediately;
//   * OPTIONALLY (publish_file checkbox, default OFF) also copies the blob
//     to the public remote, mints + stores a download URL, and emits an
//     Update with the url[] populated.
//
// v1 is synchronous: the response is not returned until the archive put
// (and, if requested, the public put + link mint) completed or failed.

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
import ap/outbox
import ap/persist
import web/server
import web/multipart
import web/html/upload
import web/handler/item
import interp/str   // byte-count: a total C-backed primitive (see below)

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
        val summary = parts.field("summary").default("")
        val content = parts.field("content").default("")
        val rating = clamp-rating(parts.field("rating").default("99").parse-int.default(99))
        val in-reply-to = parts.field("in_reply_to").default("")
        val tags = parse-tags(parts.field("tags").default(""))
        match files(parts)
          // A FILE-LESS review: a pure-text review that references a resource
          // (e.g. a book on bookwyrm) by its URL, with no blob. The file is
          // optional now — annexwyrm reviews are not only file archives.
          Nil ->
            val name = parts.field("name").default("")
            ingest-textonly(name, summary, content, rating, in-reply-to, tags)
          Cons(f, _) ->
            val name = parts.field("name").default(f.filename)
            // The publish-file checkbox: present (any value) ⇒ publish now.
            val publish-now = parts.field("publish_file").is-just
            ingest(f, name, summary, content, rating, in-reply-to, publish-now, tags)

// A file-less review: build a Note-kind item with no blob (byte 0, no sha,
// no remotes, not published), persist it + its tags, and federate the Create.
// Mirrors ingest's tail but skips all the blob machinery.
fun ingest-textonly(
    name : string, summary : string, content : string,
    rating : int, in-reply-to : string, tags : list<string>
  ) : <db,time,rng,log,config,div|e> response
  val now = now-iso()
  val owner = get-base-url() ++ "/users/" ++ get-local-username()
  val slug = rand-hex(12)
  val id = get-base-url() ++ "/items/" ++ slug
  val it = Annex-item(
    id, owner, OkNote,
    name, summary, content, "",
    0, "",
    rating, in-reply-to,
    False, "", "",
    now, now,
    []
  )
  save-item(it)
  save-item-tags(id, tags)
  emit-create(it)
  info("upload/done-textonly", [("id", id), ("rating", rating.show)])
  see-other("/items/" ++ slug)

fun ingest(
    f : mpart,
    name : string,
    summary : string,
    content : string,
    rating : int,
    in-reply-to : string,
    publish-now : bool,
    tags : list<string>
  ) : <db,time,rng,log,config,store,crypto,div|e> response
  val now = now-iso()
  val owner = get-base-url() ++ "/users/" ++ get-local-username()
  val slug = rand-hex(12)
  val id = get-base-url() ++ "/items/" ++ slug
  val media = if f.media-type == "" then "application/octet-stream" else f.media-type
  val sha = b64-encode(sha256(f.body))
  // byte-count, NOT .count: the file body is raw binary riding in a Koka
  // string, so codepoint counting undercounts (UTF-8 continuation bytes
  // are skipped). byte-count is the real on-disk size.
  val byte-size = byte-count(f.body)

  // --- Mandatory archive put -------------------------------------------
  // Copy the blob to the encrypted archive remote and VERIFY it landed.
  // The store effect has no failure channel, so we probe with blob-has;
  // a failed/half-written put aborts the upload BEFORE any item row or
  // Create exists. This is the single most important invariant here.
  val archive-loc = Blob-loc(get-archive-remote(), slug)
  blob-put(archive-loc, f.body)
  if !blob-has(archive-loc) then
    error("upload/archive-put-failed",
      [("remote", get-archive-remote()), ("slug", slug)])
    server-error("archive put failed: blob could not be written to " ++
                 get-archive-remote())
  else
    // Record the archive mirror row (published=0, the encrypted backend).
    val archive-remote = Item-remote(
      RkRclone, get-archive-remote() ++ "/" ++ slug, media,
      "archive (encrypted)", False, 0
    )
    val mt-kind = guess-kind(media)
    val it1 = Annex-item(
      id, owner, mt-kind,
      name, summary, content, media,
      byte-size, sha,
      rating, in-reply-to,
      False, "", "",
      now, now,
      [archive-remote]
    )
    save-item(it1)
    // Tags must be persisted BEFORE emit-create — emit-create reads them
    // back (load-item-tags) to build the federated `tag` Hashtag array.
    save-item-tags(id, tags)
    // The review federates immediately, archived file and all.
    emit-create(it1)

    if !publish-now then
      info("upload/done",
        [("id", id), ("size", byte-size.show), ("file_published", "0")])
      see-other("/items/" ++ slug)
    else
      // Publish the file inline: the bytes are still in hand (f.body), so
      // we do NOT round-trip through the archive remote here.
      if publish-file-blob(it1, slug, f.body) then
        info("upload/done",
          [("id", id), ("size", byte-size.show), ("file_published", "1")])
        see-other("/items/" ++ slug)
      else
        server-error("public put failed: blob could not be published to " ++
                     get-public-remote())

fun guess-kind( media : string ) : object-kind
  match media-type/parse(media)
    Just(mt) -> object-kind/from-media(mt)
    Nothing  -> OkDocument
