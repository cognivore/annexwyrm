// annexwyrm — main entry point.
//
// Subcommands:
//   init <data-dir>       Create data dir, run schema, mint a keypair.
//   serve                  Open the socket, install handlers, run forever.
//   dump-actor             Print the local actor JSON-LD.
//   ingest <file>          Register a file in the archive.
//   publish <item-id>      Flip an item private → public, emit Create.
//   unfollow <actor-url>   Send Undo Follow.
//   follow <actor-url>     Send Follow.

module annexwyrm

import std/os/env

// Effect interfaces
import effects/log
import effects/time
import effects/rng
import effects/db
import effects/config
import effects/crypto
import effects/fetch
import effects/deliver
import effects/store
import effects/shell

// Concrete interpreters
import interp/log_console
import interp/time_real
import interp/rng_urandom
pub import interp/db_sqlite
import interp/config_env
import interp/crypto_openssl
import interp/curl_bridge
import interp/shell_proc
import interp/store_rclone
import interp/socket_serve

// Algorithms
import core/types
import core/json
import ap/activity      // ap-activity returned by emit-* helpers
import ap/actor
import ap/outbox
import ap/inbox
import ap/deliver_worker
import ap/persist
import annex/item         // fresh-item, for `delete` (build a minimal shell)
import annex/storage      // seed the admin tenant's storage row from env
import web/handler/item   // load-item, for `publish` (re-announce)
import web/route
import web/server

// ----------------------------------------------------------------------
//  Entry point
// ----------------------------------------------------------------------

pub fun main() : io ()
  val args = get-args()
  match args
    Cons("serve", _)            -> cmd-serve()
    Cons("drain", _)            -> cmd-drain()
    Cons("init", Cons(d, _))    -> cmd-init(d)
    Cons("dump-actor", _)       -> cmd-dump-actor()
    Cons("publish", Cons(i, _)) -> cmd-publish(i)
    Cons("refresh", Cons(i, _)) -> cmd-refresh(i)
    Cons("delete", Cons(i, _))  -> cmd-delete(i)
    Cons("follow", Cons(a, _))  -> cmd-follow(a)
    Cons("unfollow", Cons(a, _)) -> cmd-unfollow(a)
    _ -> usage()

fun usage() : console ()
  println("usage: annexwyrm <serve|drain|init DIR|dump-actor|publish ID|refresh ID|delete ID|follow URL|unfollow URL>")

// ----------------------------------------------------------------------
//  init: create database + minted keypair
// ----------------------------------------------------------------------

fun cmd-init( data-dir : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  // We open the DB after creating the dir; we assume the user pre-mkdired.
  val db-path = data-dir ++ "/annexwyrm.db"
  val h = kk-db-open(db-path)
  if h < 0 then println("failed to open " ++ db-path)
  else
    apply-schema(h)
    with with-sqlite-db(h)
    info("init/db-opened", [("path", db-path)])
    create-local-actor-if-absent()
    install-password-if-set()
    bootstrap-admin()
    println("annexwyrm initialised in " ++ data-dir)

fun apply-schema( h : int ) : <io,log|e> ()
  val rc = kk-db-init-schema(h)
  if rc == 0 then info("init/schema-applied", [])
  else error("init/schema-failed", [("rc", rc.show)])

fun create-local-actor-if-absent() : <ndet,db,time,rng,log,config,crypto|e> ()
  val existing = query("SELECT id FROM actor WHERE local = 1 LIMIT 1", [])
  match existing
    Cons(_,_) -> info("init/actor-exists", [])
    Nil ->
      val (priv, pubkey) = rsa-keygen()
      val a = build-local-actor(get-base-url(), get-local-username(),
                                get-instance-name(), "", pubkey)
      val now = now-iso()
      exec(
        "INSERT INTO actor (id, local, username, domain, name, summary, " ++
        "inbox, outbox, followers, following, shared_inbox, public_key_pem, " ++
        "private_key_pem, manually_approves, discoverable, created_at) " ++
        "VALUES (?,1,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [txt(a.id), txt(a.preferred-username), txt(get-domain()),
         txt(a.name), txt(a.summary),
         txt(a.inbox), txt(a.outbox), txt(a.followers), txt(a.following),
         txt(a.shared-inbox), txt(a.public-key-pem), txt(priv),
         num(0), num(1), txt(now)]
      )
      info("init/actor-created", [("id", a.id)])

// If ANNEXWYRM_PASSWORD is non-empty in the environment, upsert a
// local_login row so the local actor can sign in.  Idempotent: re-run
// with a new password to change it.
fun install-password-if-set()
  : <ndet,db,time,log,crypto,config|e> ()
  match get-env-value("ANNEXWYRM_PASSWORD")
    Just(p) | p != "" ->
      val actor-id = get-base-url() ++ "/users/" ++ get-local-username()
      val phc = argon2id-hash(p)
      val now = now-iso()
      exec(
        "INSERT OR REPLACE INTO local_login (actor_id, password_hash, created_at) " ++
        "VALUES (?,?,?)",
        [txt(actor-id), txt(phc), txt(now)]
      )
      info("init/password-set", [("actor", actor-id)])
    _ ->
      info("init/no-password",
        [("hint", "set ANNEXWYRM_PASSWORD before `just init` to enable login")])

// Promote the env-configured bootstrap actor to admin and (re)seed its
// storage row from the environment. Run on BOTH `init` and `serve` start: the
// admin's blob backend is env-managed (ANNEXWYRM_*_REMOTE), so a restart with
// the operative env wins — this is also why the e2e, whose archive/public env
// is set on `serve` (not `init`), gets the right temp-dir remotes. The admin's
// rclone_conf is "" (the daemon's ambient ~/.config/rclone). New tenants
// configure their own storage via /settings; this never touches their rows.
fun bootstrap-admin() : <db,time,config,log|e> ()
  match query("SELECT id FROM actor WHERE local = 1 AND username = ? AND domain = ?",
              [txt(get-local-username()), txt(get-domain())]).first-text
    Nothing -> info("bootstrap/no-admin-actor", [("user", get-local-username())])
    Just(admin-id) ->
      val _ = exec("UPDATE actor SET is_admin = 1 WHERE id = ?", [txt(admin-id)])
      save-tenant-store(admin-id, "", get-archive-remote(),
                        get-public-remote(), get-public-url-base())
      info("bootstrap/admin-storage-seeded",
        [("actor", admin-id), ("archive", get-archive-remote())])

// ----------------------------------------------------------------------
//  serve: the HTTP loop
// ----------------------------------------------------------------------

fun cmd-serve() : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-fetch
  with with-curl-deliver
  with with-process-shell
  with with-rclone-store
  val data-dir = get-data-dir()
  val db-path = data-dir ++ "/annexwyrm.db"
  val h = kk-db-open(db-path)
  if h < 0 then println("could not open db: " ++ db-path)
  else
    // Apply schema + idempotent migration on open too, so a daemon started
    // against a DB created under the old (privacy) schema gains the
    // file-publication columns without a separate `init`.
    apply-schema(h)
    with with-sqlite-db(h)
    // Keep the admin tenant's flag + storage in sync with the env on each
    // start (see bootstrap-admin). New tenants are untouched.
    bootstrap-admin()
    val socket-path = env-or-socket()
    val fd = kk-aw-listen(socket-path)
    if fd < 0 then
      error("serve/listen-failed", [("path", socket-path)])
    else
      info("serve/listening", [("socket", socket-path),
                               ("base-url", get-base-url())])
      // The idle tick drains queued deliveries (see serve-tick). Operators
      // running a separate `annexwyrm drain` agent — and the federation e2e,
      // which needs delivery driven solely by explicit drains to stay
      // deterministic — set ANNEXWYRM_SERVE_DRAIN=0 to make it a no-op,
      // leaving the accept thread to do nothing but serve. Either tick
      // captures no value struct (koka#654 stays clear).
      val tick = if serve-drain-enabled() then (fn() serve-tick()) else (fn() ())
      serve-loop(fd, dispatch, tick, 5000)

// Whether the serve loop drains deliveries on idle. Default on; set
// ANNEXWYRM_SERVE_DRAIN=0 to delegate delivery to an external `annexwyrm
// drain` and keep the accept thread free of blocking POSTs.
fun serve-drain-enabled() : ndet bool
  match get-env-value("ANNEXWYRM_SERVE_DRAIN")
    Just(v) -> v != "0"
    Nothing -> True

// Periodic maintenance run by the serve loop on idle. Drains a SMALL batch
// (each delivery is a blocking curl POST on this accept thread, so the
// batch bounds the worst-case idle stall to batch×curl-timeout; the
// separate `annexwyrm drain` agent does bulk off-thread). Logs the count at
// info ONLY when it did work, so an idle daemon's log stays quiet.
// drain-deliveries' row (<db,time,log,config,crypto,deliver>) is a subset
// of cmd-serve's installed handler stack, so it discharges with no extra
// `with`.
fun serve-tick() : <db,time,log,config,crypto,deliver|e> ()
  val n = drain-deliveries(4)
  if n > 0 then info("serve/drained", [("count", n.show)])

fun env-or-socket() : ndet string
  match get-env-value("ANNEXWYRM_SOCKET")
    Just(v) | v != "" -> v
    _ -> "/tmp/annexwyrm.sock"

// ----------------------------------------------------------------------
//  drain: process the delivery queue once, then exit
// ----------------------------------------------------------------------

// Manual lever for ops + a deterministic trigger for the federation e2e.
// Installs the same handlers drain-deliveries needs, drains one batch of
// 64, prints the processed count, and exits.
fun cmd-drain() : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-openssl-crypto
  with with-curl-deliver
  val data-dir = get-data-dir()
  val db-path = data-dir ++ "/annexwyrm.db"
  val h = kk-db-open(db-path)
  if h < 0 then println("could not open db: " ++ db-path)
  else
    with with-sqlite-db(h)
    val n = drain-deliveries(64)
    println(n.show)

// ----------------------------------------------------------------------
//  CLI helpers
// ----------------------------------------------------------------------

fun cmd-dump-actor() : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  val db-path = get-data-dir() ++ "/annexwyrm.db"
  val h = kk-db-open(db-path)
  if h < 0 then println("could not open db: " ++ db-path)
  else
    with with-sqlite-db(h)
    val rows = query("SELECT public_key_pem FROM actor WHERE local = 1 LIMIT 1", [])
    val pem = rows.first-text.default("")
    val a = build-local-actor(get-base-url(), get-local-username(),
                              get-instance-name(), "", pem)
    println(json/show-pretty(ap-actor/to-json(a)))

fun cmd-publish( item-id : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-deliver
  with with-process-shell
  with with-rclone-store
  val h = kk-db-open(get-data-dir() ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    // Re-announce: emit a fresh Create for an existing item (with its current
    // federated representation + tags). Used to re-federate after a
    // representation change, or to (re-)deliver to a follower. Accepts a full
    // item URL or a bare slug.
    val full = if item-id.starts-with("http").bool then item-id
               else get-base-url() ++ "/items/" ++ item-id
    match load-item(full)
      Nothing  -> println("no such item: " ++ full)
      Just(it) ->
        info("cli/publish", [("id", full)])
        emit-create(it)
        println("re-announced Create for " ++ full)

// Force remote servers to re-ingest an item with its CURRENT representation:
// emit a Delete (so a stale copy — e.g. one Mastodon classified as a reply
// from an old inReplyTo — is removed) THEN a fresh Create. The drain delivers
// them in order (Delete first). Accepts a full item URL or a bare slug.
fun cmd-refresh( item-id : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-deliver
  with with-process-shell
  with with-rclone-store
  val h = kk-db-open(get-data-dir() ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    val full = if item-id.starts-with("http").bool then item-id
               else get-base-url() ++ "/items/" ++ item-id
    match load-item(full)
      Nothing  -> println("no such item: " ++ full)
      Just(it) ->
        info("cli/refresh", [("id", full)])
        emit-delete(it)
        emit-create(it)
        println("emitted Delete + Create for " ++ full)

// Tombstone an item on remote servers: emit a Delete (Tombstone) for its id.
// Only id + owner matter for the Delete, so this works even after the local
// item row is gone — build a minimal shell. Accepts a full URL or a slug.
fun cmd-delete( item-id : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-deliver
  with with-process-shell
  with with-rclone-store
  val h = kk-db-open(get-data-dir() ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    val full = if item-id.starts-with("http").bool then item-id
               else get-base-url() ++ "/items/" ++ item-id
    val owner = get-base-url() ++ "/users/" ++ get-local-username()
    val shell = fresh-item(full, owner, OkNote, "", "", 0, "", now-iso())
    info("cli/delete", [("id", full)])
    emit-delete(shell)
    println("emitted Delete for " ++ full)

fun cmd-follow( target-url : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-fetch
  with with-curl-deliver
  val h = kk-db-open(get-data-dir() ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    info("cli/follow", [("target", target-url)])
    emit-follow(target-url, get-base-url() ++ "/users/" ++ get-local-username())

fun cmd-unfollow( target-url : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-deliver
  val h = kk-db-open(get-data-dir() ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    info("cli/unfollow", [("target", target-url)])
    emit-undo-follow(target-url, get-base-url() ++ "/users/" ++ get-local-username())
