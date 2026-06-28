# annexwyrm

> a federated git-annex archive — yours, mirrored, optionally shared

Annexwyrm watches a folder. Drop in something you're reading, listening to or
watching; it is registered, hashed, optionally uploaded to one or more remotes
through rclone (Rsync.net, Google Drive, S3, …), and tracked as *private*.
Later you can *publish* an item: it becomes an
[ActivityPub](https://www.w3.org/TR/activitypub/) object that anyone who
follows your actor sees in their inbox.

Every item supports the **N-remote** pattern: when you register a file, you
can attach as many reserve URLs / rclone targets / git-annex special-remotes
as you like (`[+]` adds another row). The same `Document`/`Audio`/`Video`
serialised over the wire lists every mirror in its `url` array — the spec
allows this and modern fediverse clients pick a working one.

## Multitenant, invite-only

One annexwyrm instance hosts **many tenants**. Registration is **invite-only**:
the admin (the bootstrap actor) mints a single-use link at `/invites`, and
`/register?invite=<token>` creates a new tenant. All tenants share one
browsable archive — **anyone logged in can view (download) anyone's files** —
but **each tenant brings its own rclone/backup configuration**: a tenant's
uploads land on *that tenant's* cloud, and a cross-tenant download is
decrypted/streamed through the **owner's** rclone config, never the viewer's.
Each tenant is a first-class fediverse actor signing with its own key.

The full design, authorization rules, storage flow, and security/trust
boundaries are in [`docs/MULTITENANCY.md`](docs/MULTITENANCY.md).

There is **no JavaScript**. Pages are rendered server-side; forms POST
`multipart/form-data`; navigation is page refreshes. The aesthetic is
Reddit v1 / `lainchan` — dense text on cream, almost no chrome.

## Architecture

Annexwyrm is written in [Koka](https://koka-lang.github.io/) and structured
around **Oleg Kiselyov's Final Tagless** style: every side-effect is a Koka
*algebraic effect* (a typed interface), every algorithm is written against
those interfaces, and concrete behaviour is supplied by *handlers* installed
at the program boundary.

```
┌─────────────────────────────────────────────────────────┐
│  pure algorithms  (src/ap/, src/annex/, src/web/)       │
│   – AP semantics, inbox dispatch, HTML rendering        │
│   – speak only through effect interfaces                │
└─────────────────────────────────────────────────────────┘
        │ Log │ Time │ Rng │ Db │ Store │ Sign │ Fetch │ Deliver │ Shell │
┌─────────────────────────────────────────────────────────┐
│  interpreters     (src/interp/, csrc/)                  │
│   – SQLite, OpenSSL, libcurl, rclone, git-annex, socket │
└─────────────────────────────────────────────────────────┘
```

Effects are **independent**: nothing in the algorithms forces
`Sign` and `Db` to know about each other. A test handler can replace
`Deliver` with one that just records messages in a list; the rest of the
program is unchanged.

### The pieces

```
src/
├── core/                 atoms used everywhere
│   ├── types.kk          Id, Url, MediaType, Privacy, …
│   ├── url.kk            URL parsing
│   └── json.kk           JSON value + hand-rolled parser/printer
│
├── effects/              effect interfaces (Final Tagless)
│   ├── log.kk            structured logging
│   ├── time.kk           wall clock + ISO 8601
│   ├── rng.kk            cryptographic random
│   ├── db.kk             persistent state
│   ├── store.kk          blob storage (rclone, git-annex)
│   ├── sign.kk           HTTP Signatures (sign + verify)
│   ├── fetch.kk          outbound GET (resolve remote actors)
│   ├── deliver.kk        outbound POST (federation delivery)
│   └── shell.kk          run subprocess (escape hatch)
│
├── ap/                   ActivityPub
│   ├── actor.kk          Person/Application JSON-LD
│   ├── activity.kk       Create/Update/Delete/Follow/Accept/…
│   ├── object.kk         Note/Article/Document/Audio/Video/Image
│   ├── collection.kk     OrderedCollection + paging
│   ├── addressing.kk     to/cc/followers/Public resolution
│   ├── webfinger.kk      acct: resolution
│   ├── nodeinfo.kk       /.well-known/nodeinfo
│   ├── inbox.kk          dispatch incoming activities
│   └── outbox.kk         build outbox, deliver activities
│
├── annex/                the archive
│   ├── item.kk           the AnnexItem record
│   ├── remote.kk         remote storage targets (N per item)
│   ├── publish.kk        private → public state machine
│   └── scan.kk           watch-folder ingestion
│
├── web/                  HTTP plumbing
│   ├── server.kk         request/response types, main loop
│   ├── route.kk          URL → handler dispatch
│   ├── multipart.kk      multipart/form-data parser
│   ├── handler/          per-endpoint handlers
│   └── html/             HTML templates (pure string functions)
│
├── interp/               concrete effect implementations
│   ├── log_console.kk    Log → stderr
│   ├── time_real.kk      Time → host clock
│   ├── rng_urandom.kk    Rng → /dev/urandom
│   ├── db_sqlite.kk      Db → SQLite via csrc/sqlite_bridge.c
│   ├── store_rclone.kk   Store → rclone CLI via csrc/proc.c
│   ├── sign_openssl.kk   Sign → OpenSSL via csrc/crypto.c
│   ├── fetch_curl.kk     Fetch → libcurl via csrc/curl.c
│   └── deliver_curl.kk   Deliver → libcurl via csrc/curl.c
│
└── annexwyrm.kk          main: parse args, install handlers, listen
```

```
csrc/                     thin C bridge — no policy, only mechanics
├── annexwyrm.h           shared types and helpers
├── socket_server.c       accept() loop on Unix socket; HTTP/1.1 parser
├── db_bridge.c           sqlite3_* wrapper (embeds the schema)
├── crypto_bridge.c       RSA-SHA256, SHA-256, base64, Argon2id
├── curl_bridge.c         libcurl easy-interface wrapper
├── proc_bridge.c         fork/exec subprocess wrapper
├── rng_bridge.c          /dev/urandom
├── time_bridge.c         clock + ISO 8601 / RFC 7231 formatting
└── str_bridge.c          byte-length helper
```

Top level:

```
flake.nix                 nix inputs + dev shell + packages.default
nix/package.nix           the build derivation
Justfile                  task runner (build / serve / db / …)
.envrc                    `use flake` — direnv-friendly
Caddyfile.example         reverse-proxy config for the daemon
sql/schema.sql            authoritative schema (also embedded in csrc/db_bridge.c)
static/style.css          the only CSS
```

### Why Koka

Two reasons. First, **effect handlers** make Final Tagless natural — no
typeclass gymnastics, no transformer towers; declare `effect { … }`, write
algorithms that mention the effect in their row, and install
`with handler { … }` at the boundary. Second, Koka **compiles to C** via the
[Perceus](https://koka-lang.github.io/koka/doc/book.html#sec-perceus) memory
manager, so we link straight into a single static binary that talks to
SQLite, OpenSSL, libcurl with no runtime overhead.

### Why no HTTP server in Koka

Caddy already does HTTP/2, HTTP/3, TLS, ALPN, ACME, virtual hosts, rate
limiting, log rotation, gzip and metrics — well. Re-implementing any of
that in Koka would be a year of distraction. Instead the daemon listens
on a **Unix domain socket** speaking minimal HTTP/1.1; Caddy reverse-proxies
to that socket. The `Caddyfile.example` shipped here is the entire HTTP
configuration.

### Local dev — annexwyrm.localhost via music-box

On a host with the music-box-managed Caddy (the same setup that defines
`zensurance.localhost`, `mirror-gallery.localhost`, etc.), drop the
provided per-site Caddyfile into `~/Caddy/sites/`:

```bash
ln -s "$PWD/nix/annexwyrm.Caddyfile" ~/Caddy/sites/annexwyrm.Caddyfile
launchctl kickstart -k gui/$(id -u)/com.memorici.caddy    # darwin
# systemctl --user reload caddy                            # linux
```

Then run the daemon against the same socket path:

```bash
ANNEXWYRM_SOCKET="$HOME/.local/share/annexwyrm/sock" just serve
```

`http://annexwyrm.localhost/` is then live. (See `nix/annexwyrm.Caddyfile`
for the socket path and static-asset handling — identical shape to
`~/Caddy/sites/zensurance.Caddyfile`, just unix-socket instead of TCP.)

For uploads, Caddy streams the body through unmodified; our multipart parser
in `src/web/multipart.kk` runs against the Unix socket the same way it would
against a TCP socket. Body size is capped by Caddy (`request_body max_size`)
and re-checked by us.

## Build

Everything is Nix. No `apt`, no `brew`, no `cargo`, no shell installers.

```bash
# Enter the dev shell (or set up direnv: `direnv allow` once)
nix develop

# Compile (uses koka from the shell's PATH; result goes to ./build/)
just build

# Or the fully sandboxed, reproducible build:
just nix-build           # produces ./result/bin/annexwyrm
```

`just --list` shows every recipe. The dev shell brings in `koka`,
`sqlite`, `openssl`, `curl`, `libargon2` (build deps) and `rclone`,
`git-annex`, `git-annex-remote-rclone`, `caddy`, `jq` (runtime deps),
all from `nixpkgs-unstable` pinned in `flake.lock`.

## Run

```bash
# 1. Initialise data directory and actor keypair
just init                                  # uses $ANNEXWYRM_DATA, default ./data

# 2. Start the daemon (foreground; supervise with systemd, s6, runit, …)
ANNEXWYRM_DOMAIN=annexwyrm.example.com \
ANNEXWYRM_SOCKET=/run/annexwyrm/sock \
just serve

# 3. Put Caddy in front (see Caddyfile.example)
just caddy                                 # or `sudo caddy run --config Caddyfile.example`
```

Optional CLI commands:

```bash
just dump-actor                    # print the actor JSON-LD
./build/annexwyrm follow user@remote.example
./build/annexwyrm publish ITEM_ID
just db                            # drop into sqlite3 shell
```

## Federation in a nutshell

- The actor lives at `https://your.domain/users/you` and is fetched as
  `application/activity+json`. The same URL served as `text/html` shows a
  human-readable profile with the JSON-LD embedded in
  `<script type="application/ld+json">`.
- WebFinger at `/.well-known/webfinger?resource=acct:you@your.domain`
  hands out the actor URL.
- Followers POST `Follow` to your `inbox`. Annexwyrm auto-`Accept`s
  (unless `manually_approves_followers` is set in `settings`).
- When you `publish` an item, annexwyrm creates a `Create` whose object is
  the matching `Document`/`Audio`/`Video`/`Article`/`Note`, signs each
  outbound POST with `RSA-SHA256` HTTP Signatures, and delivers to every
  shared inbox of your followers (de-duplicated).
- Incoming `Like`/`Announce` accrete onto the local object's `likes` /
  `shares` collection; `Undo` reverses.

## Design rules

These are baked into the code review process; they are non-negotiable:

1. **Effects don't know about each other.** No effect interface mentions
   another. They are composed at the algorithm level.
2. **Algorithms don't know about interpreters.** Pure functions in `src/ap/`,
   `src/annex/`, `src/web/` only call effect operations; never `fetch_curl`
   directly.
3. **No effect in pure data.** `Activity` is a value type. Building one
   does not log, hit the clock, hit the DB. Only the algorithm that *emits*
   it touches effects.
4. **HTML is a pure function.** `render_actor : actor -> html-string`.
   Tests can compare its output to a fixture.
5. **The C bridge is a thin shim.** No policy lives in `csrc/`. Every
   function in `csrc/` corresponds to one extern in `src/interp/`.

## License

AGPL-3.0-or-later. See `LICENSE`.
