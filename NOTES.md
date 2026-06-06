# Notes — annexwyrm build state, idiomatic workarounds, SQL typing

## Build state (Koka 3.2.3 in the dev shell)

`just build` produces a working binary; `just test-e2e` runs against it
and reports 11/11 green (upload public + private PDFs, two reviews
linking between them, anonymous browse asserts 404 on private and 200
on public). The 56 Koka modules now compile cleanly. There remain three
non-obvious quirks worth flagging:

1. **Koka 3.2.3 backend codegen bug — koka-lang/koka#654**:
   ```
   internal error: Backend.C.genLambda: ap/outbox/@mlift-emit-create has
   multiple value type fields that each contain both raw types and
   regular types.
   ```
   Fires when a monadically-lifted lambda captures a `value struct` that
   mixes raw fields (`int`, `bool`, enum) with reference fields
   (`string`, `list`, `json`).

   **Workaround we now use (idiomatic):** keep the types as `value
   struct`, but never *construct + multi-effect-tail* in one function.
   Each `emit-*` in `src/ap/outbox.kk` builds the activity inside a pure
   helper (`build-create-activity`, `build-update-activity`, etc.) that
   carries only the `config` effect, then passes the returned struct to
   `ship-activity`. The synthetic `@mlift-emit-*` lambda then captures
   only primitives, not the value struct. This matches `lib/std/time/
   date.kk`'s shape: value structs in pure constructors, effects in
   separate functions.

2. **Pervasive `div` annotations**: every function that transitively
   uses our hand-rolled JSON parser or `url-decode` needs `<div|e>` in
   its effect row. The compiler is explicit about it; just append `,div`
   when it complains.

3. **C bridge gotchas worth remembering**:
   - `\x1f` in adjacent C literal context eats the next hex digit
     (`\x1ff` → 0x1FF → out of range). `proc_bridge.c` uses octal
     `\037`.
   - SIGPIPE: a peer closing mid-write (curl `--max-time`, nc `-z`
     probes) kills the daemon unless `signal(SIGPIPE, SIG_IGN)` runs
     early. `csrc/socket_server.c:kk_aw_listen` ignores it.
   - `--ccincdir` resolves relative to where the C compiler runs (under
     `.koka/.../cc-...`), not where `koka` was invoked from. The
     Justfile uses `$(pwd)/csrc` to make it absolute.
   - **darwin dev-shell `just build` vs `nix build .#default`**: koka's
     nixpkgs wrapper pins `CC=clang-wrapper-21.1.8`, so both paths use the
     *same* compiler. But inside `nix develop` the aggregate
     `NIX_CFLAGS_COMPILE` injects a `-isystem .../libcxx-…+apple-sdk-26.4/
     include` ahead of the real `apple-sdk-14.4` sysroot. For a **C**
     compile that stray libcxx dir shadows the SDK's `<time.h>`, so
     `time_t`/`gmtime_r`/`strftime` come up undefined and the bridge fails
     with "unknown type name 'time_t'" + implicit-declaration errors. The
     sandboxed `nix build .#default` has a *minimal* `buildInputs` (no
     stray libcxx), so its include path reaches the SDK cleanly and the
     binary it produces is sound (verified: real ISO timestamps, RSA PEM,
     argon2 login row). **Canonical build = `nix build .#default`.** The
     e2e harness builds via that, not `just build`; `just build` may work
     on other hosts but is not the source of truth here.
   - **Linux/gcc portability (surfaced deploying to Ubuntu chat.md110.se;
     clang-on-darwin masked both):**
     - The C bridge header MUST NOT be named `annexwyrm.h` — koka generates
       a module header `annexwyrm.h` for `src/annexwyrm.kk` into the same cc
       builddir as the generated `interp_*.c`, so a quote-include of
       `"annexwyrm.h"` resolves to koka's module header, not the bridge's
       (aw_* + <time.h> vanish). It's now `csrc/aw_bridge.h`. Don't rename
       it back, and don't add a koka module whose name collides with a csrc
       header.
     - No C identifier may be named `unix`: gcc predefines the macro
       `unix`=1 on Linux, so `int unix` becomes `int 1`. The time effect's
       param is `epoch`, not `unix`.
   - `package.nix` installs the binary with `install -m555`, not `cp`:
     koka's sandbox-emitted binary is mode 0644 and a bare `cp` leaves the
     store path non-executable, so launchd's `serve` agent would die with
     EACCES.

What it took to get this far otherwise: changing all extern effects
from `io` to `ndet` / `<ndet,net>` / `<ndet,fsys>`, single-clause `with
handler` blocks instead of stacked `with fun X`, escaping every `raw`
/ `pub` / `handle` identifier (those are Koka keywords), renaming
`dispatch-or-400` to `dispatch-or-bad` (identifiers must not end in a
digit-after-dash), and importing `ap/activity` explicitly in `annexwyrm.kk`
even though it's transitively visible through `ap/outbox`.

## SQL typing — your question

### Is the SQL type-safe?

**No.** What we have is:

```kk
pub effect db
  fun query( sql : string, params : list<sql-value> ) : list<sql-row>
  fun exec ( sql : string, params : list<sql-value> ) : int
```

The compiler can't see inside `sql`. We could:

- Write `"SELECT id, name FROM items WHERE rating > ?"` and pass three
  params — nothing complains.
- Read `r.col(0)` as `SqlText` when it's actually `SqlInt`.
- Reorder columns in the schema and silently drift the handlers.

### Is the `db` effect marked correctly?

**Yes.** Every function that ever touches a query/exec carries `db` in
its effect row, and `with-sqlite-db` is the only place that discharges
it. So you cannot accidentally hit the database from a pure-render
function — the type checker rejects it. That's the win Final Tagless
gave us. The gap is *between the effect signature and the query
payload itself*.

### What we DO get from the C bridge

`csrc/db_bridge.c:bind_one` binds every value through
`sqlite3_bind_text/int64/null` with `SQLITE_TRANSIENT`. Values are never
concatenated into the SQL string. So:

- **SQL injection is structurally impossible** in our code — the worst
  bug is `column out of range` at runtime, not eaten data.

### Path to actually typed SQL, in order of effort vs. payoff

1. **Per-table accessor modules** (`src/annex/item_db.kk`,
   `src/ap/follow_db.kk`, …) where every SQL string lives once and is
   wrapped in a typed function. Two hours of refactoring, catches ~90 %
   of real-world drift.

2. **`prepared-stmt<row-type>` phantom rows** — Koka can carry a type
   parameter that names the columns. Then `r.col-of(field-name)` only
   compiles for that row type. Real type safety, ~a day of work, requires
   we hand-write the row types once.

3. **Codegen from `sql/schema.sql`** — once the schema is stable, parse
   it at build time and emit Koka row types automatically.

Right now (1) is the obvious next move, especially because half of our
`text(r.col(0))` boilerplate would disappear.

## What's complete and what isn't

| area | state |
|---|---|
| Effect interfaces (Final Tagless) | done |
| AP domain (Actor/Object/Activity/Collection/Addressing/Sign/Webfinger/Nodeinfo) | done |
| Annex domain (Item/Remote/Publish/Scan) with `rating : int` (-3..+3) and `in-reply-to` | done |
| HTML templates with rating badges + review-of preamble | done |
| Web routing + multipart parser + per-route handlers | done |
| Interpreters (sqlite, openssl, libcurl, rclone via shell, /dev/urandom, time) | done |
| C bridge (8 files in `csrc/`) | done |
| Nix flake + Justfile + `nix/package.nix` | done |
| E2E harness (`tests/e2e/run.sh`, `make-pdf.py`, `lib.sh`) | wired but not yet runnable until the binary builds |
| Google Drive verification via rclone | flag-gated (`ANNEXWYRM_E2E_GDRIVE=1`) but waiting on binary |
| Typed per-table SQL accessors | NOT done — addressed in NOTES, planned |

## How the rating renders

- 7-point Likert: `-3, -2, -1, 0, +1, +2, +3`, plus the unrated
  sentinel `99` (meaning "no opinion submitted").
- Text badge: `[+3]`, `[ 0]`, `[-2]` — Reddit-v1 style, monospaced.
- Stars: filled `★` for positive, hollow `☆` for negative, count
  matching the magnitude. `+3` = `★★★`, `-2` = `☆☆`, `0` = nothing.
- CSS: `.rating.positive` (green), `.negative` (maroon), `.neutral`
  (muted). See `static/style.css`.
- AP wire: `"annexwyrm:rating": -2` in the object JSON-LD, with
  `annexwyrm` declared in `@context` as
  `https://annexwyrm.example.com/ns#`. Other servers ignore it; we
  surface it.

## Reviews

A "review" is just an `annex-item` with a non-empty `in-reply-to`. The
item page renders a small "review of &lt;hyperlinked URL&gt;" preamble
above the title. The review's `content` is HTML, so `<a href="…">`
inside it Just Works — that's what the e2e test verifies once we get the
binary to build.

## Bridge record framing (the binary-body invariant)

Every C↔Koka bridge record framed with `\x1f` separators carries AT
MOST ONE binary field, and that field goes LAST. Real binary payloads
(PDF/JPEG/audio) contain `0x1F` about once per 256 bytes, so a binary
field anywhere else silently truncates at the first one — which is
exactly how the first real phone upload to prod died with "expected
multipart/form-data" while every ASCII-fixture e2e stayed green.

The rule, enforced at each site:

- C encoders strip `0x1F` from every NON-final field (hostile local
  socket peers and hostile federation remotes must not be able to
  shift the frame), and append the binary field raw after the last
  separator. See `socket_server.c` (request → `…\x1fHEADERS\x1fBODY`),
  `proc_bridge.c` (spawn → `EXIT\x1fSTDERR\x1fSTDOUT`),
  `curl_bridge.c` (response → `STATUS\x1fHEADERS\x1fBODY`).
- Koka decoders use `split-limit` (`interp/str`): peel the n
  separator-free fields, keep the remainder byte-exact. Never
  `split("\x1f")` a record whose last field can be binary.
- Sizes of binary-in-string data use `byte-count`, never `.count`
  (codepoint counting skips UTF-8 continuation bytes and undercounts).

Regression coverage: `tests/e2e/run.sh` Steps G/H upload fixtures
containing every byte value 0x00–0xFF and assert byte-exact blobs and
exact `byte_size`/`sha256` through upload, publish-on-upload, and
publish-later (`blob-get`).

## Editing reviews

GET/POST /items/<id>/edit (owner-gated) edits a review's title, abstract,
body HTML, rating, and review-of target. It federates an AP `Update` and
never touches the file blob or its publication state — editing text does
not republish or retract the file. A review (item with in_reply_to) is
first-class editable, including retargeting the review-of link, and a
PUBLISHED review keeps its download link through an edit. The form is
application/x-www-form-urlencoded (no file part), parsed by query-parse.

url-decode is two-phase (resolve %XX/'+' to bytes, then re-interpret as
UTF-8) so multibyte titles (accents, CJK, emoji) round-trip byte-exact;
the edit form is the first path to send rich user text through query-parse
(uploads use multipart). parse-pair splits on the first '=' only.

### Known follow-up (low priority)
- item_remote.created_at is rewritten to the edit time on every save-item
  (save-remote writes i.updated-at, not a per-remote created_at). Harmless
  today — created_at is not selected by load-remotes nor displayed — but
  to make it faithful, add a created-at field to the item-remote value
  struct, SELECT it in load-remotes, set it in fresh-remote, and write
  r.created-at in save-remote. Touches the positional Item-remote literals
  in upload.kk and publish.kk; keep them positional (koka#654).

## Security audit (2026-06-06) — fixes + standing follow-ups

A full adversarial audit (9 dimensions, double-verified) ran against the
whole codebase. Fixed in this pass:

ActivityPub S2S (the internet-facing inbox):
- **keyId↔actor binding** (was CRITICAL: full impersonation). verify-signature
  now rejects unless the keyId's actor == the activity actor (same-actor),
  and the activity id shares an origin with the actor (same-origin — blocks
  id-dedup poisoning). src/web/handler/inbox.kk.
- **Required digest + minimum signed-header set** — an inbound POST must sign
  (request-target) host date digest, so the body can't be unauthenticated.
- **Anti-replay** — the signed Date must be within ±12h (parse-http-date,
  csrc/time_bridge.c). Replays outside the window are rejected.
- **IDOR** — Undo/Accept/Reject DELETE/UPDATE are scoped to the acting actor
  (follower_id/actor_id/target_id = a.actor), not just the inner id.
- **SSRF egress filter** — curl is restricted to http/https and a sockopt
  callback rejects loopback/private/link-local/CGNAT/ULA targets (covers the
  inbox keyId fetch AND delivery). Test seam: ANNEXWYRM_ALLOW_PRIVATE_EGRESS=1
  (e2e only — NEVER prod). csrc/curl_bridge.c.
- **curl response cap** 8 MiB (egress memory DoS).

DoS / parsing:
- **JSON depth guard** (max 64) pre-scans before the recursive parser, on the
  unauthenticated inbox path. src/core/json.kk.
- **Socket recv timeout** (30s) + O(n) header scan — slowloris can't pin the
  single serve thread. csrc/socket_server.c.

DB / memory:
- **0x1E/0x1F/TAB byte-stuffing** in the SQLite param + result framing — a
  remote AP field with a control byte no longer truncates/shifts binds or
  desyncs result parsing. src/interp/db_sqlite.kk + csrc/db_bridge.c.
- **PBKDF2-fallback stack overflow** fixed (decode buffers sized before the
  decode). csrc/crypto_bridge.c. (Only reachable on -DANNEXWYRM_NO_ARGON2.)
- **memcpy(NULL,0)** UB guarded in proc_bridge.c.

Web:
- **SameSite=Strict** session cookie + **session rotation** on login (drops
  prior sessions). **actor summary escaped** (remote-controlled → was raw).

Prod edge (nginx, not in the binary): limit_req on /login and /inbox, and
client_max_body_size aligned to the daemon's 64 MiB cap. See deploy.sh notes.

Regression tests: federation F7.1 (forged actor → 401), F7.2 (stale-Date
replay → 401), F7.3 (JSON depth-bomb → 400, daemon survives); socket Step L
(control-byte DB round-trip, byte-exact hex).

### Standing follow-ups (low priority, accepted for now)
- exec()/query() return -1 on bind/SQLITE_BUSY is not surfaced to callers.
  Root cause (0x1E binds) is fixed and busy_timeout=5000 covers contention;
  a typed Result on the db effect would make the rest loud. [[]]
- Login username enumeration via argon2 timing — MOOT here: the single tenant
  username is public. Left as-is.
- Cleartext ANNEXWYRM_PASSWORD in the serve process env (only init needs it);
  rageveil protects it at rest. A nix-module change could unset it before
  exec serve.
