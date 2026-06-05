# SPEC — Two-instance ActivityPub S2S federation test for annexwyrm

**File to produce:** `tests/e2e/run-federation.sh` (TCP helpers reused from `tests/e2e/lib.sh`).
**Audience:** the engineer who writes the test.
**Status of this document:** normative. Every "MUST" is a hard assertion. "If it didn't crash, ship it" is forbidden. Each step asserts an exact, observable fact on **both** instances.

This is the FIRST real federation system test: two live annexwyrm daemons, each behind its own Caddy, talking ActivityPub server-to-server over HTTP, with the delivery queue actually draining a signed POST from one instance's outbox into the other's inbox.

---

## 0. Read this first — what the code actually supports today

Before a line is written, the investigation below is load-bearing. Every design choice in this spec follows from a fact in the source. The numbered **FINDINGS** in §6 are the capability gaps; each one names the workaround this spec uses. Do not "fix" the code to make a step pass — this is a *test* spec; it tests the system **as it is**, and documents every seam as a seam.

The single most important fact:

> **`drain-deliveries` (src/ap/deliver_worker.kk) is defined but called from nowhere.** There is no `annexwyrm drain` subcommand (src/annexwyrm.kk dispatches only `serve|init|dump-actor|publish|follow|unfollow`), and the serve loop (`serve-go` in src/interp/socket_serve.kk) blocks on `kk-aw-accept` — it never ticks the queue. `kk-aw-accept-timeout` exists in the C bridge but is unused. **Nothing in a stock binary ever POSTs a queued delivery.**

Therefore this spec is written in **two tiers**:

- **Tier 1 (the real S2S wire test) requires a `drain` subcommand** — a ~12-line addition to `src/annexwyrm.kk` (see §5, *Prerequisite*). With it, the full signed Create travels A↔B over HTTP and lands in the peer DB. This is the test we want.
- **Tier 0 (the fallback)** is what passes against a *completely unmodified* binary: it proves the queue is *populated correctly* (the rows that a drain *would* send) and proves the *inbound* path end-to-end by POSTing a hand-signed activity to the peer's real inbox with `curl`. It does NOT exercise the daemon's own delivery POST.

The test MUST detect which tier is available (does `"$BINARY" drain --help` / `"$BINARY" drain` exist?) and run Tier 1 if the subcommand is present, else Tier 0. Both tiers assert the same DB end-state on the receiver. **The supervisor decides whether to land the `drain` subcommand; the test must be honest either way.** Default expectation for landing: Tier 1.

---

## 1. The journey, and why this exact direction

Two instances:

| | **A** ("the follower / the publisher's audience") | **B** ("the publisher") |
|---|---|---|
| username | `ayla` | `belgarath` |
| data dir | `$TMP/A/data` | `$TMP/B/data` |
| socket | `$TMP/A/sock` | `$TMP/B/sock` |
| Caddy port | `$A_PORT` | `$B_PORT` |
| Caddy admin port | `$A_ADMIN` | `$B_ADMIN` |
| **base URL** | `http://127.0.0.1:$A_PORT` | `http://127.0.0.1:$B_PORT` |
| actor id | `http://127.0.0.1:$A_PORT/users/ayla` | `http://127.0.0.1:$B_PORT/users/belgarath` |
| inbox | `.../users/ayla/inbox` | `.../users/belgarath/inbox` |

**Why `http://127.0.0.1:$PORT` as the base URL (not a hostname).** This is the linchpin (FINDING 5). `init` mints every id and inbox URL from `ANNEXWYRM_BASE_URL` (`local-actor-url` / `build-local-actor` in src/ap/persist.kk, src/ap/actor.kk). When B publishes, B's Create carries `actor=http://127.0.0.1:$B_PORT/users/belgarath`; when A receives it, A's signature-verification path **fetches that actor URL with libcurl** (src/ap/actor_cache.kk → `fetch-actor`). The C bridge (`csrc/curl_bridge.c`) sets `CURLOPT_FOLLOWLOCATION=0` and sends **no Host override** — it hits whatever host is literally in the URL. So every minted id MUST be directly fetchable as written. Setting each instance's base URL to `http://127.0.0.1:$PORT` makes ids self-resolving cross-instance with zero DNS or Host-header trickery. (Contrast run-caddy.sh, which uses a hostname base URL and a `Host:` header for *transport only* because it never fetches its own absolute ids cross-process. We can't do that here.) Each Caddy site block is therefore keyed on `127.0.0.1:$PORT` directly (§4), and curl talks to it with no `Host:` gymnastics.

**The chosen happy-path journey (the direction the code supports):**

1. **A follows B.** A's follow handler (`handle-follow-action`, src/web/handler/follow.kk) calls `resolve-actor(B, refresh=False)` which, on a cache miss, **fetches B's actor document over HTTP and caches it** (inbox, public key — `fetch-actor`/`cache-actor`). Then `emit-follow(B)` mints a Follow, writes a `follow` row `state=pending`, looks up B's now-cached inbox, and **queues one delivery** (src/ap/outbox.kk `ship-follow`). This is the outbound-follow path that works *because A fetched B first* (FINDING 1: `emit-follow` itself caches nothing; the handler's `resolve-actor` call is what populates the actor row — without it `ship-follow` would log `outbox/follow: target inbox unknown` and queue nothing).
2. **B receives A's Follow** (drain delivers it in Tier 1; curl POSTs it in Tier 0). B's inbox handler (`dispatch-inbox` → `verify-signature`, src/web/handler/inbox.kk) **fetches and caches A's actor** to get A's public key (FINDING 3), verifies the HTTP signature, then `handle-follow` writes a `follow` row and — because `manuallyApprovesFollowers=0` by default (src/annexwyrm.kk init) — **auto-accepts**: `auto-accept-follow` mints an Accept, flips the follow row to `accepted`, and **queues an Accept delivery back to A** (src/ap/inbox.kk).
3. **A receives B's Accept** (drain/curl): A's `handle-accept` promotes A's pending follow row to `accepted` (src/ap/inbox.kk). **Now A is an accepted follower of B on both sides.**
4. **B publishes an item.** B uploads a public item (`POST /upload`), then `POST /items/<id>/publish` runs `emit-create` (src/web/handler/item.kk → src/ap/outbox.kk). `resolve-recipients` expands the Create's `cc=[B/followers]` (public items address `to=[Public], cc=[followers]`, src/annex/publish.kk `build-addressing`) via `followers-inboxes`, which returns **the inbox of every `state='accepted'` follower** — i.e. A's inbox (src/ap/persist.kk). One delivery row is queued for A.
5. **The drain delivers the signed Create to A's inbox.** B's `drain-deliveries` signs (Date/Digest/Signature, RSA-SHA256 draft-cavage, src/ap/sign.kk `sign-outbound`) and POSTs to A's real inbox URL. A verifies B's signature (B's actor already cached from step 2), dispatches, and **records the remote Create activity** (`record-activity(..., inbox-remote=True)`, src/ap/inbox.kk `handle-inbox-activity`). The delivery row on B transitions `pending → success`.

**Why not the reverse (B publishes, A "pulls")?** There is no pull. Federation here is push-only via the `delivery` queue, and the queue only fans out to **accepted followers** (`followers-inboxes` filters `state='accepted'`). So the audience relationship MUST exist first. The follow handshake above is the only way the code builds it, and A-follows-B is the direction with a working outbound trigger (a logged-in HTTP `POST /follow`). B-follows-A would need the same on B; we only need one direction, so we use it.

**Out of scope:** retry/backoff (this is the happy path — §6 FINDING 7 says delivery rows go straight `pending → success`, never touching `mark-retry`), WebFinger `acct:` resolution (we use absolute actor URLs; FINDING 6), manual follow approval, TLS, multi-item fan-out, Likes/Announces/Undo over the wire.

---

## 2. Environment, invocation, knobs

- Runs **inside the Nix dev shell** (`nix develop -c bash tests/e2e/run-federation.sh`), which provides `caddy`, `curl`, `python3`, `nc`, `sqlite3`, `jq`, `openssl`.
- Canonical build is **`nix build .#default`** (the dev-shell `just build` is broken on this darwin host — NOTES.md). Binary resolution mirrors run.sh / run-caddy.sh exactly: if `ANNEXWYRM_BINARY` is set use it, else `nix build .#default --out-link "$REPO/result"` and use `$REPO/result/bin/annexwyrm`. Assert `[ -x "$BINARY" ]`.
- **This file is new** — it MUST be `git add`ed before `nix build` can see anything it references, and it MUST appear in CI alongside `run.sh` (61 asserts) and `run-caddy.sh` (110 asserts); all three MUST stay green.
- `set -euo pipefail`. A single `trap cleanup EXIT INT TERM` MUST kill **both** daemons and **both** Caddys (track four PIDs) and `rm -rf "$TMP"` unless `KEEP_TMP=1` (then leave it, print the path). On any non-zero exit, dump all four logs (`$TMP/A/daemon.log`, `$TMP/A/caddy.run.log`, `$TMP/B/daemon.log`, `$TMP/B/caddy.run.log`) and both access logs to stderr first.
- **Four free ephemeral ports** on 127.0.0.1 via the `free_port()` python probe from run-caddy.sh: `A_PORT`, `A_ADMIN`, `B_PORT`, `B_ADMIN`. Never hardcode.
- Daemon logs go to **stderr** (src/interp/log_console.kk via `kk_aw_log_line`, flushed per line), captured to `$TMP/<I>/daemon.log`. Log lines have the shape `[LEVEL] msg key1=val1 key2=val2` (`with-console-log`).
- BSD/macOS shell discipline (lib.sh notes): **no `awk` IGNORECASE**; parse headers with `grep -i`; reuse `caddy_curl`/`header_value`/`assert_status_tcp`/`assert_via_caddy`/`upload_tcp` from lib.sh but **per-instance** (see §4.2). Explicit assertions only.

---

## 3. Identity fixtures (set once, reused everywhere)

```
A_USER="ayla";       A_DOMAIN="127.0.0.1"   # (the literal host of A's base URL)
B_USER="belgarath";  B_DOMAIN="127.0.0.1"
A_PASS="fed-e2e-A";  B_PASS="fed-e2e-B"
A_INSTANCE="ayla's annexwyrm (fed e2e A)"
B_INSTANCE="belgarath's annexwyrm (fed e2e B)"
# After ports are probed:
A_BASE="http://127.0.0.1:$A_PORT"          # ANNEXWYRM_BASE_URL for A
B_BASE="http://127.0.0.1:$B_PORT"          # ANNEXWYRM_BASE_URL for B
A_ACTOR="$A_BASE/users/$A_USER"
B_ACTOR="$B_BASE/users/$B_USER"
A_INBOX="$A_ACTOR/inbox"
B_INBOX="$B_ACTOR/inbox"
A_DB="$TMP/A/data/annexwyrm.db"
B_DB="$TMP/B/data/annexwyrm.db"
```

`ANNEXWYRM_DOMAIN` for each instance is set to `127.0.0.1` (so `get-domain()` matches the host in the minted ids; the unique index `actor_local_user(domain,username)` and any webfinger domain check stay coherent). Because both instances share the host `127.0.0.1` and differ only by port, **use the port to disambiguate in every assertion** — never assert on host alone.

---

## 4. Setup: two parallel stacks

Build **A** and **B** stacks identically; everything below is done **per instance**. Where run-caddy.sh has one of something, this test has two, namespaced `A_`/`B_`.

### 4.1 Caddyfile per instance

Mirror run-caddy.sh's Caddyfile, but **key the site block on the IP:port directly** (we hit it by IP:port and our minted ids use that authority, so no hostname indirection):

```
{
    admin 127.0.0.1:${A_ADMIN}
}

http://127.0.0.1:${A_PORT} {
    encode zstd gzip
    request_body {
        max_size 4GB
    }
    reverse_proxy unix/${A_SOCK} {
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            versions 1.1
            read_buffer 64KB
            write_buffer 64KB
        }
    }
    log {
        output file ${A_CADDY_ACCESS_LOG}
        format json
    }
}
```

(No `/static` block needed — this suite asserts no CSS.) **`caddy validate` each Caddyfile** and assert exit 0 (the multi-line `request_body` discipline, bug #3, still applies). Repeat for B with `B_ADMIN`/`B_PORT`/`B_SOCK`.

### 4.2 TCP helpers, namespaced

lib.sh's `caddy_curl` and friends read the globals `CADDY_BASE`/`CADDY_HOST`. We talk to two bases, so DO NOT rely on a single global. Define thin per-instance wrappers in the test:

```
# Talk to instance I by IP:port. No Host trickery: the site block is keyed on
# 127.0.0.1:$PORT and our ids use that authority, so a plain curl matches.
a_curl() { curl --silent --show-error "$@"; }   # URLs are full http://127.0.0.1:$A_PORT/...
b_curl() { curl --silent --show-error "$@"; }
```

For header dumps / Location / Via / Set-Cookie extraction, reuse `header_value` (it is base-agnostic — it parses a header blob). For status, write a 2-arg `assert_status_url URL EXPECTED LABEL` that curls a full URL. **Every response from either Caddy still carries `Via: 1.1 Caddy`; assert it (`assert_via_caddy`) on at least the first GET of each instance to prove we are proxied, not hitting a socket by accident.**

### 4.3 Start order

1. `init` A's data dir with A's full env (incl. `ANNEXWYRM_PASSWORD=$A_PASS`); `init` B's with B's. Assert each DB's local actor id equals `$A_ACTOR` / `$B_ACTOR` (catches base-URL drift, the bug-#4 family).
2. Start daemon A (`serve`, A's env minus password, `> $TMP/A/daemon.log 2>&1 &`), `wait_for_socket "$A_SOCK" 10`, then the "speaks HTTP over socket" retry loop. Same for B.
3. Start Caddy A and Caddy B (each `caddy run --config … --adapter caddyfile > …caddy.run.log 2>&1 &`), poll each `GET /` until any status (bounded loop, **no foreground sleep**). Assert all four PIDs alive and no `panic|internal error|EACCES` in either daemon log.

**Cross-reachability smoke (MUST):** before any federation, prove each instance can fetch the *other's* actor as JSON-LD (this is exactly what the sig path will do):

- `a_curl -H 'Accept: application/activity+json' "$B_ACTOR"` → status `200`, body is JSON with `"id":"http://127.0.0.1:$B_PORT/users/belgarath"` and a `publicKey.publicKeyPem` containing `BEGIN PUBLIC KEY`. (Use `jq -e '.id, .publicKey.publicKeyPem'`.)
- Symmetric: `b_curl … "$A_ACTOR"` → A's actor JSON-LD.
- Assert `Via: 1.1 Caddy` on both — proves the actor doc is served through the peer's proxy, the same path libcurl will traverse. (The daemon's `handle-actor` returns `ok-jsonld` for an `application/activity+json` Accept; src/web/handler/actor.kk.)

---

## 5. The federation steps — three observable truths each

For every step: **(a)** client/instance-visible HTTP facts, **(b)** exact daemon log line shapes on **both** instances, **(c)** exact SQL on **both** DBs. Log-line assertions use `assert_log_grep` (grep -E over the per-instance daemon log). The `[0-9a-f]+` in id patterns matches `rand-hex(12)` minted ids; the `127\.0\.0\.1:PORT` authority disambiguates instances.

> **Prerequisite for Tier 1 (the drain subcommand).** Tier 1 requires the binary to support a one-shot `annexwyrm drain` that opens the DB and calls `drain-deliveries(batch)` under the same handler stack `cmd-serve` already installs (`with-openssl-crypto`, `with-curl-deliver`, `with-curl-fetch`, `with-sqlite-db`, `with-real-time`, `with-console-log`, `with-env-config`). The drain's effect row is `<db,time,log,config,crypto,deliver|e>` (src/ap/deliver_worker.kk) — every one of those handlers is already in `cmd-serve`'s scope, so the subcommand is a copy of `cmd-serve`'s `with`-stack minus `kk-aw-listen`, plus `val n = drain-deliveries(50); println("drained " ++ n.show)`. **If `drain` is absent, the test runs Tier 0** and explicitly logs `note "drain subcommand absent → Tier 0 (no daemon-side delivery POST)"`. The test selects the tier by probing: run `"$BINARY" drain "$B_DATA"` once on an empty queue; if it exits 0 and logs nothing fatal, Tier 1 is available.

---

### Step F1 — A logs in, then A follows B

A authenticates (so the follow handler's `is-owner-session` passes), then issues the follow.

**(a) HTTP**
- `POST $A_BASE/login` (form `username=ayla&password=fed-e2e-A`, `--data-urlencode`, no `-L`, cookie jar `$A_JAR`) → `303`, `Location: /`, `Set-Cookie: session=…` (no `Secure` over http://). `Via: 1.1 Caddy`.
- `POST $A_BASE/follow` with cookie jar and form body `target=$B_ACTOR` (`--data-urlencode "target=$B_ACTOR"`, no `-L`) → `303`, `Location: /`. `Via` present. (Handler returns `see-other("/")`; src/web/handler/follow.kk.)

**(b) daemon logs**
- **A** MUST log the actor fetch of B and the follow emission, in order:
  - the outbound GET of B's actor is not itself logged by name, but its **effect** is: B's actor row now exists on A (asserted in (c)). A MUST log `^\[info\] outbox/publish` is NOT used for follows; the follow path logs nothing on success in `ship-follow` **except** the warning it must NOT emit:
  - A MUST **NOT** log `outbox/follow: target inbox unknown` (that line means the actor fetch failed and nothing was queued — a hard failure here). Assert its **absence** (`! grep -q 'outbox/follow: target inbox unknown' "$A_DAEMON_LOG"`). This is the headline assertion that FINDING 1's workaround (handler pre-fetch) actually fired.
- **B** MUST log serving its actor document to A's fetch: a request line for `GET /users/belgarath`. (The daemon does not log GETs by a dedicated line; instead assert via **B's Caddy access log** that a `GET /users/belgarath` with status `200` was served — `jq` the JSON access log for `.request.uri=="/users/belgarath"` and `.status==200`. This is the over-the-wire proof that A fetched B's actor through B's Caddy.)

**(c) SQL**
- **A_DB**: B is now a cached remote actor, and a pending follow exists.
  - `SELECT count(*) FROM actor WHERE id='$B_ACTOR' AND local=0;` MUST be `1` (FINDING 1 workaround proof: the handler's `resolve-actor` cached B).
  - `SELECT inbox FROM actor WHERE id='$B_ACTOR';` MUST equal `$B_INBOX`.
  - `SELECT length(public_key_pem) > 0 FROM actor WHERE id='$B_ACTOR';` MUST be `1`.
  - `SELECT count(*) FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR' AND state='pending';` MUST be `1`.
  - The Follow activity row: `SELECT type FROM activity WHERE actor_id='$A_ACTOR' AND type='Follow';` MUST be `Follow`; `SELECT object_id FROM activity WHERE type='Follow' AND actor_id='$A_ACTOR';` MUST equal `$B_ACTOR`.
  - **One delivery queued to B's inbox, pending:** `SELECT count(*) FROM delivery WHERE inbox_url='$B_INBOX' AND state='pending';` MUST be `1`. Capture the Follow activity id: `FOLLOW_AID=$(sqlite3 "$A_DB" "SELECT id FROM activity WHERE type='Follow' AND actor_id='$A_ACTOR';")` and assert `SELECT activity_id FROM delivery WHERE inbox_url='$B_INBOX';` equals `$FOLLOW_AID`, `sender_id` equals `$A_ACTOR`, `attempts=0`.
- **B_DB**: nothing yet — the Follow has only been *queued* on A, not delivered.
  - `SELECT count(*) FROM follow;` MUST be `0`.
  - `SELECT count(*) FROM activity WHERE inbox_remote=1;` MUST be `0`.

---

### Step F2 — deliver A's Follow to B (drain or curl)

**Tier 1 (drain):** run `"$BINARY" drain "$A_DATA"` with A's env. It reads A's `delivery` queue, signs with A's private key (`key-id = $A_ACTOR#main-key`), and POSTs the Follow to `$B_INBOX` (which is `127.0.0.1:$B_PORT` → B's Caddy → B's daemon).

**Tier 0 (curl fallback):** there is no daemon POST, so the test reproduces the *exact bytes* the drain would send, using A's private key from the DB:
- `BODY=$(sqlite3 "$A_DB" "SELECT raw FROM activity WHERE id='$FOLLOW_AID';")`
- Extract A's private key: `sqlite3 "$A_DB" "SELECT private_key_pem FROM actor WHERE id='$A_ACTOR';" > $TMP/A.key`
- Build the draft-cavage signing string for headers `(request-target) host date digest` exactly as src/ap/sign.kk `sign-outbound` does: `digest = "SHA-256=" + base64(sha256(body))` (match `http-digest`; verify its exact prefix in src/effects/http.kk or csrc — assert the receiver accepts it, which is the real check), `host = 127.0.0.1:$B_PORT`, `date =` RFC 7231 now, request-target `post /users/belgarath/inbox`. Sign with `openssl dgst -sha256 -sign`, base64 the signature, assemble the `Signature:` header via the same field order as `build-signature-header`. POST with `Date`, `Digest`, `Signature`, `Content-Type: application/activity+json`.
- **Tier 0 is explicitly a stand-in for the daemon's POST and MUST be commented as such.** It still exercises B's *real* inbound path end to end (parse → fetch A's actor → verify sig → dispatch → persist), which is the half the daemon can't currently drive itself.

**(a) HTTP**
- The POST to `$B_INBOX` MUST return **`202`** (`accepted-empty`, src/web/server.kk — the fediverse convention; src/web/handler/inbox.kk `handle-after-verify`). A `401` here means signature verification failed (FINDING 3 — B couldn't fetch/verify A's key); a `400` means dispatch rejected it. Assert exactly `202`.
- In Tier 1 the status is observed only in B's Caddy access log (`POST /users/belgarath/inbox` → `202`); assert that via `jq`. In Tier 0 the curl returns it directly; assert the `--write-out '%{http_code}'` is `202`.

**(b) daemon logs**
- **B** MUST log, in order:
  - `^\[info\] inbox/dispatch id=$A_BASE/activities/[0-9a-f]+ type=Follow$` (`handle-inbox-activity`; note the id is one of **A's** minted activity ids, authority `127.0.0.1:$A_PORT`).
  - It MUST **NOT** log `inbox/unsigned` (that means the signature was missing/invalid → 401). Assert absence.
  - It MUST **NOT** log `inbox/follow: queued for manual approval` (default is auto-accept; assert absence) and MUST **NOT** log `inbox/follow: target is not us` (the Follow's object is `$B_ACTOR`, which is B; assert absence).
  - It MUST **NOT** log `inbox/follow: follower actor not cached` — that warning fires in `auto-accept-follow` only if A's actor wasn't resolved; its absence proves FINDING 3's auto-fetch of A's actor for verification *also* satisfied the inbox lookup. Assert absence.
- **A** (Tier 1 only): the drain run MUST log nothing fatal; assert A's daemon/drain output has no `panic|internal error`. (The drain is a separate short-lived process; capture its stdout/stderr to `$TMP/A/drain.f2.log` and assert it printed `drained 1` or similar and exited 0. The exact string is whatever the drain subcommand prints — assert it mentions `1`.)

**(c) SQL**
- **B_DB** now reflects the received-and-auto-accepted follow:
  - `SELECT count(*) FROM actor WHERE id='$A_ACTOR' AND local=0;` MUST be `1` (B fetched + cached A for verification — FINDING 3). `SELECT inbox FROM actor WHERE id='$A_ACTOR';` MUST equal `$A_INBOX`.
  - `SELECT state FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR';` MUST be `accepted` (auto-accept flipped it; the row id is **A's** Follow activity id, `$FOLLOW_AID`). Assert `SELECT id FROM follow WHERE follower_id='$A_ACTOR';` equals `$FOLLOW_AID`. `SELECT accepted_at IS NOT NULL FROM follow WHERE id='$FOLLOW_AID';` MUST be `1`.
  - The inbound Follow activity is persisted: `SELECT count(*) FROM activity WHERE id='$FOLLOW_AID' AND inbox_remote=1;` MUST be `1`.
  - The Accept B minted back to A is queued: `SELECT count(*) FROM delivery WHERE inbox_url='$A_INBOX' AND state='pending';` MUST be `1`. Capture `ACCEPT_AID=$(sqlite3 "$B_DB" "SELECT id FROM activity WHERE type='Accept' AND actor_id='$B_ACTOR';")`; assert that activity's `object_id` references the Follow (`SELECT raw LIKE '%$FOLLOW_AID%' FROM activity WHERE id='$ACCEPT_AID';` MUST be `1`) and the delivery's `sender_id='$B_ACTOR'`, `attempts=0`.
- **A_DB**: A's delivery for the Follow MUST now be `success` (Tier 1) — `SELECT state FROM delivery WHERE activity_id='$FOLLOW_AID';` MUST be `success`. **In Tier 0**, the daemon never sent it, so A's delivery row is still `pending`; the test MUST assert `pending` in Tier 0 and `success` in Tier 1, and say which (`note`). A's follow row stays `pending` until F3.

---

### Step F3 — deliver B's Accept back to A (drain or curl)

**Tier 1:** `"$BINARY" drain "$B_DATA"` with B's env → signs B's Accept, POSTs to `$A_INBOX`.
**Tier 0:** reproduce the POST of `ACCEPT_AID` to `$A_INBOX` with B's private key, same recipe as F2 (host `127.0.0.1:$A_PORT`, request-target `post /users/ayla/inbox`).

**(a) HTTP** — POST to `$A_INBOX` MUST return `202`. (A already has B cached from F1, so verification needs no new fetch; but the code will still `resolve-actor(B)` and hit cache.)

**(b) daemon logs**
- **A** MUST log `^\[info\] inbox/dispatch id=$B_BASE/activities/[0-9a-f]+ type=Accept$` and MUST NOT log `inbox/unsigned`.
- **B** (Tier 1): drain log → `drained 1`, exit 0, no panic.

**(c) SQL**
- **A_DB**: `SELECT state FROM follow WHERE id='$FOLLOW_AID';` MUST be `accepted` (`handle-accept` promoted A's pending row; src/ap/inbox.kk — the UPDATE matches `WHERE id=$FOLLOW_AID AND state='pending'`). `SELECT accepted_at IS NOT NULL FROM follow WHERE id='$FOLLOW_AID';` MUST be `1`. The Accept is persisted inbound: `SELECT count(*) FROM activity WHERE id='$ACCEPT_AID' AND inbox_remote=1;` MUST be `1`.
- **B_DB** (Tier 1): `SELECT state FROM delivery WHERE activity_id='$ACCEPT_AID';` MUST be `success`. (Tier 0: still `pending`; assert accordingly.)

**Checkpoint (assert on both DBs):** A is now an accepted follower of B as seen from **both** sides:
- `SELECT state FROM follow WHERE follower_id='$A_ACTOR' AND target_id='$B_ACTOR';` MUST be `accepted` on **A_DB and B_DB**.

---

### Step F4 — B publishes a public item

B logs in, uploads a public PDF, then publishes it (the publish endpoint is what fires `emit-create`; the upload itself does not — src/web/handler/upload.kk has no `emit-*`, FINDING 4).

**(a) HTTP**
- `POST $B_BASE/login` (`belgarath`/`fed-e2e-B`, jar `$B_JAR`) → `303`, session cookie, `Via`.
- Upload via `upload_tcp`-style multipart (reuse the field discipline: `-F file=@$PDF;type=application/pdf`, `--form-string` for `name=Federated Treatise`, `summary=`, `content=<p>Across the wire.</p>`, `privacy=public`, `rating=99`, `in_reply_to=`) to `$B_BASE/upload` with `$B_JAR`, no `-L` → `303`, `Location` matching `^/items/[0-9a-f]+$`. Capture `ITEM_PATH`; `ITEM_URL="$B_BASE$ITEM_PATH"`.
- `POST $B_BASE$ITEM_PATH/publish` (jar, empty body, no `-L`) → `303`, `Location: $ITEM_PATH`. `Via`.

**(b) daemon logs (B)**
- `^\[info\] upload/done id=$ITEM_URL size=[0-9]+ remotes=0` (the upload, src/web/handler/upload.kk).
- `^\[info\] outbox/publish id=$B_BASE/activities/[0-9a-f]+ type=Create recipients=1` — **`recipients=1`** is the headline: the Create fanned out to exactly one inbox (A's), because A is B's only accepted follower (`resolve-recipients` → `followers-inboxes`, src/ap/outbox.kk `ship-activity`). A regression to `recipients=0` (e.g. follow not accepted, or `cc` not addressing `/followers`) fails here loudly. This is the assertion that proves the *whole handshake mattered*.

**(c) SQL (B_DB)**
- `SELECT privacy FROM item WHERE id='$ITEM_URL';` MUST be `public`.
- Exactly one outbound Create: `SELECT count(*) FROM activity WHERE type='Create' AND object_id='$ITEM_URL' AND inbox_remote=0;` MUST be `1`. Capture `CREATE_AID`. `SELECT actor_id FROM activity WHERE id='$CREATE_AID';` MUST equal `$B_ACTOR`. `SELECT raw LIKE '%\"type\":\"Create\"%' AND raw LIKE '%$ITEM_URL%' FROM activity WHERE id='$CREATE_AID';` MUST be `1`.
- **One delivery queued to A's inbox, pending:** `SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID' AND inbox_url='$A_INBOX' AND state='pending';` MUST be `1`; that row's `sender_id='$B_ACTOR'`, `attempts=0`, `last_error IS NULL`.
- No second delivery: `SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID';` MUST be `1`.

**(c) SQL (A_DB)** — nothing delivered yet: `SELECT count(*) FROM activity WHERE object_id='$ITEM_URL';` MUST be `0`.

---

### Step F5 — the drain delivers the signed Create to A; A persists it

This is the climax: a daemon-driven (Tier 1) signed POST from B's outbox to A's real inbox.

**Tier 1:** `"$BINARY" drain "$B_DATA"` (B's env). `drain-deliveries` selects B's pending Create row (`next_attempt <= now`), loads `raw` and B's `private_key_pem`, signs (`key-id=$B_ACTOR#main-key`, headers `(request-target) host date digest`), and `http-post`s to `$A_INBOX` (src/ap/deliver_worker.kk `deliver-one`). On `resp.ok` (2xx) it calls `mark-success`.

**Tier 0:** reproduce the signed POST of `CREATE_AID` to `$A_INBOX` with B's private key (same recipe as F2). Comment it as the daemon-POST stand-in.

**(a) HTTP**
- The POST to `$A_INBOX` MUST return **`202`** (A parsed, verified B's signature against B's cached key, dispatched the Create, `record-activity` succeeded, `handle-create` returned `Nothing` → `accepted-empty`). A `401` means A failed to verify B (key mismatch / digest mismatch — FINDING 3 / FINDING 8); assert exactly `202`. In Tier 1, read it from A's Caddy access log (`POST /users/ayla/inbox` → `202`); in Tier 0 from the curl write-out.

**(b) daemon logs**
- **A** MUST log `^\[info\] inbox/dispatch id=$B_BASE/activities/[0-9a-f]+ type=Create$` and MUST NOT log `inbox/unsigned` or `inbox/duplicate`. (The id is `$CREATE_AID`, authority `127.0.0.1:$B_PORT`.)
- **B** (Tier 1): drain output MUST report it sent the Create — assert `$TMP/B/drain.f5.log` contains `drained 1` (or the drain's count string mentioning `1`) and exit 0, no `panic|internal error`. This is the proof the daemon's own delivery machinery ran a real signed HTTP POST.

**(c) SQL (A_DB)** — A now holds the remote activity **and** the remote object reference:
- `SELECT count(*) FROM activity WHERE id='$CREATE_AID' AND inbox_remote=1;` MUST be `1` (the remote Create landed and is flagged inbound). 
- `SELECT actor_id FROM activity WHERE id='$CREATE_AID';` MUST equal `$B_ACTOR`.
- `SELECT object_id FROM activity WHERE id='$CREATE_AID';` MUST equal `$ITEM_URL` (the published item is the Create's object).
- `SELECT raw LIKE '%$ITEM_URL%' AND raw LIKE '%Federated Treatise%' FROM activity WHERE id='$CREATE_AID';` MUST be `1` — the **full object body B published is now stored in A's DB** (the Create embeds the object; `record-activity` persists `raw`). This is the "A's db then holds the remote activity/object" requirement. **Note (FINDING 9):** A does **not** create an `item` row for B's object — `handle-create` deliberately stores only the activity row, not arbitrary remote objects (src/ap/inbox.kk). So assert on the `activity` table, NOT on `item`; asserting an `item` row for `$ITEM_URL` on A_DB would be wrong and the test MUST instead assert its **absence**: `SELECT count(*) FROM item WHERE id='$ITEM_URL';` MUST be `0` on A_DB.

**(c) SQL (B_DB)** — the delivery transitioned **pending → success**, retry/backoff untouched:
- **Tier 1:** `SELECT state FROM delivery WHERE activity_id='$CREATE_AID';` MUST be `success`.
- `SELECT attempts FROM delivery WHERE activity_id='$CREATE_AID';` MUST be `0` — **the happy path never incremented attempts; `mark-retry`/`backoff` were never reached** (FINDING 7). This is the explicit "retry/backoff NOT exercised" assertion.
- `SELECT last_error IS NULL FROM delivery WHERE activity_id='$CREATE_AID';` MUST be `1` (no error string was ever written).
- `SELECT count(*) FROM delivery WHERE state='failed';` MUST be `0` on B_DB (nothing gave up).
- **Tier 0:** the daemon never sent it, so the Create delivery row on B is still `pending` with `attempts=0`; assert exactly that and `note` that Tier 0 does not transition the row (only Tier 1's drain does). The *receiver* end-state on A_DB is identical in both tiers.

---

### Step F6 — negative controls (prove the assertions have teeth)

- **Idempotency / dedup:** re-deliver the Create to `$A_INBOX` once more (re-run drain in Tier 1 finds nothing pending, so instead POST the same bytes again with curl in **both** tiers). A MUST return `202` again but MUST log `^\[info\] inbox/duplicate id=$CREATE_AID$` (the `SELECT 1 FROM activity WHERE id=?` guard, src/ap/inbox.kk), and A_DB's `SELECT count(*) FROM activity WHERE id='$CREATE_AID';` MUST still be `1` (no duplicate row). This proves `inbox_remote`/dedup is real, not an artifact of a single POST.
- **Unsigned rejection:** POST the Create body to `$A_INBOX` with **no `Signature` header**. A MUST return `401` and log `^\[warn\] inbox/unsigned from=$B_ACTOR type=Create` (src/web/handler/inbox.kk `handle-unsigned`; Create is not Delete, so it is rejected). A_DB activity count for `$CREATE_AID` MUST be unchanged (`1`). This proves the `202`s above were earned by a valid signature, not accepted unconditionally.

---

## 6. FINDINGS — capability gaps and the workaround this spec uses

1. **`emit-follow` caches nothing; `lookup-actor-inbox` reads only the local `actor` table.** src/ap/outbox.kk `ship-follow` calls `lookup-actor-inbox(target)` which queries the `actor` table; on a miss it logs `outbox/follow: target inbox unknown` and **queues no delivery**. The only thing that populates a remote actor row for an *outbound* follow is the **HTTP handler** `handle-follow-action` calling `resolve-actor(target, False)` **before** `emit-follow` (src/web/handler/follow.kk). The CLI `cmd-follow` (src/annexwyrm.kk) calls `emit-follow` directly with no pre-fetch, so **CLI follow of an uncached actor silently queues nothing.** **Workaround:** the test follows via the **HTTP `POST /follow`** endpoint (Step F1), never the CLI, so the handler's `resolve-actor` does the fetch+cache. The test asserts B's actor row appeared on A and that `outbox/follow: target inbox unknown` was NOT logged.

2. **No outbound actor *refresh* before publish.** `emit-create`'s `resolve-recipients` (src/ap/outbox.kk) expands followers purely from the local DB join (`followers-inboxes`, src/ap/persist.kk) — it never re-fetches. This is fine for the happy path because the follower's inbox was cached during the inbound handshake (F2). **Workaround:** none needed; the handshake must complete first, which the spec enforces (F1–F3) before F4.

3. **The receiver MUST be able to fetch the sender's actor/public key to verify a signature.** src/web/handler/inbox.kk `verify-signature` → `resolve-actor(actor-id, refresh)` → on cache miss `fetch-actor` does an HTTP GET of the keyId's actor URL (src/ap/actor_cache.kk). If that GET fails (actor URL not reachable, wrong host), verification returns `False` and the inbox replies `401`. **This is why base URLs MUST be directly fetchable IP:port (FINDING 5).** **Workaround:** `ANNEXWYRM_BASE_URL=http://127.0.0.1:$PORT` per instance + Caddy site block keyed on that IP:port; §4.3 asserts cross-reachability of both actor docs before any federation.

4. **Uploading does not federate; publishing does.** src/web/handler/upload.kk `ingest` saves the item and returns `303` but calls no `emit-*`. The Create is emitted only by `POST /items/<id>/publish` (`handle-item-publish` → `emit-create`, src/web/handler/item.kk). **Workaround:** Step F4 uploads **then** publishes; the `recipients=1` log line and the queued delivery come from the publish, not the upload.

5. **libcurl fetches the literal host in the URL; no Host override, no redirect-follow.** `csrc/curl_bridge.c` sets `CURLOPT_FOLLOWLOCATION=0` and never sets a Host header, so every minted id MUST resolve as written. A hostname base URL (like run-caddy.sh's `annexwyrm.localhost`) would not resolve cross-process without `/etc/hosts` or a Host trick that libcurl can't apply. **Workaround:** IP:port base URLs (FINDING 3). Caddy can key a site block directly on `http://127.0.0.1:$PORT`, so no `Host:` juggling is needed for transport either — a plain `curl http://127.0.0.1:$PORT/...` matches.

6. **No WebFinger `acct:` round-trip in the follow path.** `resolve-target` (src/web/handler/follow.kk) only accepts an absolute `http(s)://` actor URL or naively rewrites `user@host` to `https://host/users/user` (wrong scheme/shape for our http IP:port instances). **Workaround:** the test passes the **absolute** actor URL `target=$B_ACTOR` to `POST /follow`; it never uses the `acct:` form.

7. **Retry/backoff is happy-path-dead by construction.** `deliver-one` calls `mark-retry`/`backoff` only on a non-2xx response (src/ap/deliver_worker.kk). On the happy path every inbox returns `202`, so `mark-success` runs and `attempts` stays `0`. **The spec asserts `attempts=0`, `last_error IS NULL`, no `failed` rows** (F5) to prove retry was NOT exercised — exactly as required.

8. **Digest must match byte-for-byte or verification fails.** `verify-inbound` (src/ap/sign.kk) recomputes `http-digest(body)` and compares to the signed `Digest` header when `digest` is in the signed header set. In Tier 0, the test's hand-rolled `openssl` digest MUST use the **same algorithm and encoding** as `http-digest` (`SHA-256=` + base64 of the raw sha256). The test MUST read `http-digest`'s exact format (src/effects/http.kk / its interpreter) and match it; a mismatch surfaces as a `401` at the inbox, which the test would (correctly) fail on. **Workaround:** Tier 1 sidesteps this entirely (the daemon signs its own bytes); Tier 0 must replicate `http-digest` precisely and is the reason Tier 1 is preferred.

9. **The receiver stores the remote *activity*, not a remote *item* row.** `handle-create` (src/ap/inbox.kk) is a deliberate no-op beyond the activity row already persisted by `handle-inbox-activity` ("We do not store arbitrary remote objects unless they are replies to something we own"). **Workaround:** F5 asserts the landed object lives in `activity.raw` (and `activity.object_id=$ITEM_URL`), and asserts there is **no** `item` row for `$ITEM_URL` on A. Asserting an `item` row would be testing behavior the code does not have.

10. **THE BLOCKER: nothing drives delivery in a stock binary.** `drain-deliveries` is dead code (no caller); `serve-go` blocks on `kk-aw-accept` and never ticks; `kk-aw-accept-timeout` is wired in C but unused; `cmd-publish` is a stub (`println("not yet wired")`). **Workaround:** Tier 1 requires a tiny `drain` subcommand (§5 *Prerequisite*) — the cleanest, most honest path, and the one this spec is written to exercise. Tier 0 falls back to a `curl`-replayed signed POST that drives the **receiver's** real inbound pipeline but is explicitly NOT the daemon's own delivery POST. The test auto-selects the tier and prints which it ran. **Landing the `drain` subcommand is the recommended fix and the reason this spec exists; without it, "the drain actually delivering" cannot be claimed.**

---

## 7. Failure ergonomics (non-negotiable)

- Every assertion failure prints expected vs observed and context (failing SQL + its result, or the first ~40 lines of the response body / log tail), reusing lib.sh's `assert_*` message style.
- On any failure or early exit, the trap dumps **both** daemon logs, **both** caddy.run.logs, and (if non-empty) both access logs to stderr before cleanup.
- Cleanup kills **all four** processes (two daemons, two Caddys), `wait`s on them, then `rm -rf "$TMP"`. A leaked Caddy or daemon on a temp port is a test bug. `KEEP_TMP=1` leaves `$TMP` and prints its path.
- The test prints, at the top of its run, **which tier it selected** and why, so a green run is never silently the weaker tier.

## 8. Definition of done

The test passes **iff** every MUST holds for the selected tier. The suite has earned its place only if these sabotages turn it red:

- Skip A's pre-follow actor fetch (delete the `resolve-actor` call in `handle-follow-action`) → F1 fails (`outbox/follow: target inbox unknown` appears; no delivery row; B's actor not cached on A).
- Make B's publish address `cc=[]` instead of `[followers]` (break `build-addressing`/`item-to-ap-object`) → F4's `recipients=1` becomes `recipients=0` and the F4/F5 delivery assertions fail.
- Strip the `Signature` header on the F5 delivery → F5's `202` becomes `401` and A persists nothing (and F6's unsigned control, conversely, must already prove this).
- Point B's base URL at an unreachable host → §4.3 cross-reachability or F2's signature verification fails (B can't fetch A's key).
- (Tier 1) Remove the `drain` subcommand → the test downgrades to Tier 0 and says so; if it silently claimed Tier 1, that is itself a failure.

If any sabotage does not turn the suite red, the test does not meet this spec.

---

## Appendix A — exact log-line shapes asserted (copy targets)

| Instance / step | Pattern (grep -E over the daemon log) |
|---|---|
| B / F2 receive Follow | `^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$A_PORT/activities/[0-9a-f]+ type=Follow$` |
| A / F3 receive Accept | `^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Accept$` |
| B / F4 upload | `^\[info\] upload/done id=$B_BASE/items/[0-9a-f]+ size=[0-9]+ remotes=0` |
| B / F4 publish | `^\[info\] outbox/publish id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Create recipients=1` |
| A / F5 receive Create | `^\[info\] inbox/dispatch id=http://127\.0\.0\.1:$B_PORT/activities/[0-9a-f]+ type=Create$` |
| A / F6 dedup | `^\[info\] inbox/duplicate id=$CREATE_AID$` |
| A / F6 unsigned | `^\[warn\] inbox/unsigned from=$B_ACTOR type=Create` |
| A / F1 must be ABSENT | `outbox/follow: target inbox unknown` |
| B / F2 must be ABSENT | `inbox/unsigned`, `inbox/follow: queued for manual approval`, `inbox/follow: target is not us`, `inbox/follow: follower actor not cached` |

## Appendix B — the drain subcommand (Tier 1 prerequisite, for the supervisor)

A faithful one-shot drain, modeled on `cmd-serve`'s handler stack (src/annexwyrm.kk), effect row `<db,time,log,config,crypto,deliver|e>` from `drain-deliveries`:

```koka
fun cmd-drain( data-dir : string ) : io ()
  with with-env-config
  with with-console-log
  with with-real-time
  with with-urandom-rng
  with with-openssl-crypto
  with with-curl-fetch
  with with-curl-deliver
  val h = kk-db-open(data-dir ++ "/annexwyrm.db")
  if h < 0 then println("db open failed")
  else
    with with-sqlite-db(h)
    val n = drain-deliveries(50)
    println("drained " ++ n.show)
```

Dispatch: `Cons("drain", Cons(d, _)) -> cmd-drain(d)`. Any new code must be `git add`ed before `nix build .#default` can see it. This is the entirety of what Tier 1 needs; the delivery algorithm, signing, and queue transitions already exist in `src/ap/deliver_worker.kk`.

## Appendix C — macOS / BSD pitfalls (inherited from run-caddy.sh)

1. No `awk` IGNORECASE — parse headers with `grep -i` (reuse lib.sh `header_value`).
2. `curl -F` interprets `<`/`@` — `--form-string` for literals, `-F file=@…;type=…` only for the file (reuse `upload_tcp`'s discipline).
3. No foreground `sleep` for readiness — bounded poll loops only.
4. Two of everything: namespace all PIDs, ports, dirs, jars, logs `A_`/`B_`; the trap MUST kill all four processes.
5. `Via: 1.1 Caddy` is the proxied-path proof — assert it on each instance's first GET.
6. JSON-LD assertions use `jq -e` so a malformed/empty body fails loudly, not silently.
