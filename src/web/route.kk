// annexwyrm/web/route — URL path → handler dispatch.
//
// Pure routing: just splits the path into segments and calls the right
// handler. Handlers handle effects.

module web/route

import core/types
import core/url
import effects/db
import effects/time
import effects/rng
import effects/log
import effects/config
import effects/crypto
import effects/fetch
import effects/deliver
import effects/store
import web/server
import web/handler/home
import web/handler/actor
import web/handler/inbox
import web/handler/outbox
import web/handler/followers
import web/handler/webfinger
import web/handler/nodeinfo
import web/handler/item
import web/handler/upload
import web/handler/login
import web/handler/follow

// Split "/users/alice/inbox" → ["users", "alice", "inbox"].
fun segments( path : string ) : list<string>
  path.split("/").filter(fn(s) s != "")

// Decode each segment in turn. (We never decode the whole path because
// "/" inside a segment is unusual but possible.)
fun decode-segs( segs : list<string> ) : div list<string>
  segs.map(url-decode)

// The entry point. The set of effects this needs is the union of every
// handler — i.e. the full algorithm stack.
pub fun dispatch( req : request )
  : <db,time,rng,log,config,crypto,fetch,deliver,store,div|e> response
  val segs = decode-segs(segments(req.path))
  match (req.method, segs)
    ("GET",    Nil) ->
      handle-home(req)

    // WebFinger and friends -----------------------------------------------
    ("GET",    Cons(".well-known", Cons("webfinger", Nil))) ->
      handle-webfinger(req)
    ("GET",    Cons(".well-known", Cons("nodeinfo", Nil))) ->
      handle-nodeinfo-discovery(req)
    ("GET",    Cons("nodeinfo", Cons("2.1", Nil))) ->
      handle-nodeinfo(req)

    // Shared inbox at the bare domain root --------------------------------
    ("POST",   Cons("inbox", Nil)) ->
      handle-shared-inbox(req)

    // Actor profile + collections -----------------------------------------
    ("GET",    Cons("users", Cons(u, Nil))) ->
      handle-actor(req, u)
    ("POST",   Cons("users", Cons(u, Cons("inbox", Nil)))) ->
      handle-user-inbox(req, u)
    ("GET",    Cons("users", Cons(u, Cons("outbox", Nil)))) ->
      handle-outbox(req, u)
    ("GET",    Cons("users", Cons(u, Cons("followers", Nil)))) ->
      handle-followers(req, u)
    ("GET",    Cons("users", Cons(u, Cons("following", Nil)))) ->
      handle-following(req, u)

    // Items ---------------------------------------------------------------
    ("GET",    Cons("items", Cons(id, Nil))) ->
      handle-item(req, id)
    ("POST",   Cons("items", Cons(id, Cons("publish", Nil)))) ->
      handle-item-publish(req, id)
    ("POST",   Cons("items", Cons(id, Cons("unpublish", Nil)))) ->
      handle-item-unpublish(req, id)
    ("POST",   Cons("items", Cons(id, Cons("update", Nil)))) ->
      handle-item-update(req, id)

    // Upload / ingest -----------------------------------------------------
    ("GET",    Cons("upload", Nil)) -> handle-upload-form(req)
    ("POST",   Cons("upload", Nil)) -> handle-upload-post(req)

    // Auth ----------------------------------------------------------------
    ("GET",    Cons("login", Nil))  -> handle-login-form(req)
    ("POST",   Cons("login", Nil))  -> handle-login-post(req)
    ("POST",   Cons("logout", Nil)) -> handle-logout(req)

    // Follow / unfollow ---------------------------------------------------
    ("POST",   Cons("follow", Nil))   -> handle-follow-action(req)
    ("POST",   Cons("unfollow", Nil)) -> handle-unfollow-action(req)

    // Anything else -------------------------------------------------------
    _ -> not-found("no route: " ++ req.method ++ " " ++ req.path)
