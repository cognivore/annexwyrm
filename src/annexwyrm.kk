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
import web/route
import web/server

// ----------------------------------------------------------------------
//  Entry point
// ----------------------------------------------------------------------

pub fun main() : io ()
  val args = get-args()
  match args
    Cons("serve", _)            -> cmd-serve()
    Cons("init", Cons(d, _))    -> cmd-init(d)
    Cons("dump-actor", _)       -> cmd-dump-actor()
    Cons("publish", Cons(i, _)) -> cmd-publish(i)
    Cons("follow", Cons(a, _))  -> cmd-follow(a)
    Cons("unfollow", Cons(a, _)) -> cmd-unfollow(a)
    _ -> usage()

fun usage() : console ()
  println("usage: annexwyrm <serve|init DIR|dump-actor|publish ID|follow URL|unfollow URL>")

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
    with with-sqlite-db(h)
    val socket-path = env-or-socket()
    val fd = kk-aw-listen(socket-path)
    if fd < 0 then
      error("serve/listen-failed", [("path", socket-path)])
    else
      info("serve/listening", [("socket", socket-path),
                               ("base-url", get-base-url())])
      serve-loop(fd, dispatch)

fun env-or-socket() : ndet string
  match get-env-value("ANNEXWYRM_SOCKET")
    Just(v) | v != "" -> v
    _ -> "/tmp/annexwyrm.sock"

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
    println("not yet wired: publish " ++ item-id)

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
    val _ = emit-follow(target-url)
    ()

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
    val _ = emit-undo-follow(target-url)
    ()
