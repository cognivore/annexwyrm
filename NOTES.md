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
