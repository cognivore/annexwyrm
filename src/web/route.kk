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
import web/handler/settings
import web/handler/follow
import web/handler/search
import web/handler/register
import web/handler/invites
import web/handler/help

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
    // /items and /items/ (the "items" breadcrumb) list the archive — same as
    // home. segments() drops the trailing empty segment, so both forms match.
    ("GET",    Cons("items", Nil)) ->
      handle-home(req)
    ("GET",    Cons("items", Cons(id, Nil))) ->
      handle-item(req, id)
    ("GET",    Cons("items", Cons(id, Cons("file", Nil)))) ->
      handle-item-file(req, id)
    ("GET",    Cons("items", Cons(id, Cons("edit", Nil)))) ->
      handle-item-edit-form(req, id)
    ("POST",   Cons("items", Cons(id, Cons("edit", Nil)))) ->
      handle-item-edit-post(req, id)
    ("POST",   Cons("items", Cons(id, Cons("publish-file", Nil)))) ->
      handle-item-publish-file(req, id)

    // Help / docs ---------------------------------------------------------
    ("GET",    Cons("help", Cons("storage", Nil))) -> handle-help-storage(req)

    // Search & tags -------------------------------------------------------
    ("GET",    Cons("search", Nil)) -> handle-search(req)
    ("GET",    Cons("tags", Nil)) -> handle-tags-index(req)
    ("GET",    Cons("tags", Cons(tag, Nil))) -> handle-tag(req, tag)

    // Upload / ingest -----------------------------------------------------
    ("GET",    Cons("upload", Nil)) -> handle-upload-form(req)
    ("POST",   Cons("upload", Nil)) -> handle-upload-post(req)

    // Auth ----------------------------------------------------------------
    ("GET",    Cons("login", Nil))  -> handle-login-form(req)
    ("POST",   Cons("login", Nil))  -> handle-login-post(req)
    ("GET",    Cons("settings", Nil)) -> handle-settings-form(req)
    ("POST",   Cons("settings", Nil)) -> handle-settings-post(req)
    ("POST",   Cons("settings", Cons("storage", Nil))) -> handle-settings-storage-post(req)
    ("POST",   Cons("settings", Cons("storage", Cons("test", Nil)))) -> handle-settings-storage-test(req)
    ("POST",   Cons("logout", Nil)) -> handle-logout(req)

    // Invite-only registration + admin invite management -----------------
    ("GET",    Cons("register", Nil)) -> handle-register-form(req)
    ("POST",   Cons("register", Nil)) -> handle-register-post(req)
    ("GET",    Cons("invites", Nil))  -> handle-invites-form(req)
    ("POST",   Cons("invites", Nil))  -> handle-invites-post(req)

    // Follow / unfollow ---------------------------------------------------
    ("POST",   Cons("follow", Nil))   -> handle-follow-action(req)
    ("POST",   Cons("unfollow", Nil)) -> handle-unfollow-action(req)

    // Anything else -------------------------------------------------------
    _ -> not-found("no route: " ++ req.method ++ " " ++ req.path)
