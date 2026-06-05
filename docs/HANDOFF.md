# annexwyrm — CTO handoff

You are taking over from the previous CTO. Read this entire file before
touching any code.

## What works right now

- `just build` green inside `nix develop`. Binary at `./build/annexwyrm`.
- `just test-e2e` green: 11/11 assertions through a temp Unix socket.
  Exercises login, two uploads (public PDF + private PDF), two reviews
  with cross-links and `-3..+3` ratings, anonymous browse asserts 404
  on the private item and 200 on the public.
- Two commits on `origin/main`:
  - `638cb6d` — initial drop (with #654 workaround using reference `struct`s)
  - `6b86396` — restored `value struct`s; idiomatic emit-* split

## What does NOT work / is unverified

1. **`http://annexwyrm.localhost` through music-box-managed Caddy** —
   the most important thing left. `nix/annexwyrm.Caddyfile` is written
   but has not been symlinked into `~/Caddy/sites/`, Caddy has not been
   reloaded, and the daemon has not been pointed at the matching socket
   path (`~/.local/share/annexwyrm/sock`). This is **priority 1**.
2. **The delivery worker is wired in code but no background loop drains
   the queue.** `serve-loop` accepts requests and dispatches; nothing
   yet calls `drain-deliveries` between accept() calls. Pending
   activities sit in `delivery` rows forever.
3. **`emit-delete`, `emit-follow`, `emit-undo-follow`, `emit-like`,
   `emit-announce` still use the construct-then-tail-effect pattern in
   one body.** They compile *today*, but the same minor edit (e.g.
   adding one more effect op in the tail) can trip
   koka-lang/koka#654 the same way `emit-create` did. Apply the
   `build-*` + `ship-activity` split preemptively.
4. **Google Drive e2e (`just test-e2e-gdrive`) was never run.** The
   rclone path is wired and the user has `gdrive` configured in their
   `~/.config/rclone/rclone.conf`, but nobody has watched a real PDF
   land in `gdrive:annexwyrm-test/`. The MCP Google Drive tools were
   not consulted to confirm.
5. **SQL has no column-typed accessors.** `db` effect is correctly
   marked everywhere; injection is structurally impossible (the C
   bridge uses `sqlite3_bind_*` with `SQLITE_TRANSIENT`); but column
   index drift will silently misread rows. Per-table accessor modules
   planned, not started.
6. **Argon2id falls back to PBKDF2-SHA256 unless libargon2 headers are
   detected at C compile time.** The Nix shell ships `libargon2`; the
   `__has_include(<argon2.h>)` guard in `csrc/crypto_bridge.c` should
   succeed but has not been verified by reading the generated `.o`.

## The four mistakes the previous CTO made

If you find yourself doing any of these again, stop and back out.

1. **Started reaching for `--cclibs`, `--ccinc=csrc`, plain `-l...`
   strings.** All wrong. Koka's flag names are `--cclib="a;b;c"`
   (semicolon-separated, NO `-l` prefix) and `--ccincdir=...` (which
   resolves *relative to where the C compiler runs*, deep under
   `.koka/v3.2.3/cc-...`, NOT where `koka` was invoked). The Justfile
   uses `--ccincdir="$(pwd)/csrc"` so it stays absolute.

2. **Demoted `ap-activity` / `ap-object` to reference `struct` before
   trying the idiomatic split.** Per Plyb's note in
   koka-lang/koka#654, that *does* work but it loses the value-struct
   semantics for ~half the AP domain. The right fix is the
   `build-create-activity` + `ship-activity` shape now in
   `src/ap/outbox.kk`: pure helper constructs the value struct in a
   `config`-only effect row; the multi-effect tail receives it as a
   parameter; the synthetic `@mlift-emit-*` lambda's closure carries
   only primitives. Matches `lib/std/time/date.kk`. Use this anywhere
   you sequence "build value struct → multiple effect ops" again.

3. **Sent `curl -F "content=<p>…"` in the e2e harness without knowing
   `<` is curl's file-read directive.** Burned an hour chasing curl
   error 26 ("Failed to open/read local data") that was actually curl
   trying to open a file named `p>A document…`. Fix: in
   `tests/e2e/lib.sh`, only the file upload uses `-F`; every literal
   field uses `--form-string` (also escapes `@`, the file-attach
   directive, for free).

4. **Set `Secure;` on the session cookie before checking the dev
   path.** `Secure` means "send only over HTTPS"; dev talks `http://`
   to the Unix socket, so curl silently drops the cookie and every
   protected POST gets 403. The session cookie no longer has `Secure`
   — when you put Caddy in front for production, *Caddy* terminates
   TLS and you add `Secure` back at the reverse-proxy header level, or
   re-add it conditionally in Koka after reading `X-Forwarded-Proto`.

## The Koka fix that's ready to consume

There isn't one yet — koka-lang/koka#654 is open, no maintainer
response on the thread (as of last check), and `git log v3.2.3..dev --
src/Kind/Repr.hs` in `~/Github/koka` is empty. The dev branch's
package.yaml bump to 3.2.4–3.2.7 is a version-number-only change.
**Building Koka from `dev` will NOT fix this.** The idiomatic split
(see mistake #2) is the path.

If you want to keep tabs: poll the issue at
https://github.com/koka-lang/koka/issues/654 once a week. If a fix
lands, revisit `src/ap/outbox.kk` and see whether the
`build-create-activity` indirection is still earning its keep or can
be inlined.

## Priority order

1. **Verify `http://annexwyrm.localhost` end-to-end through Caddy.**
   Two-subagent pattern, see "How to run e2e" below. The acceptance
   criterion is: a browser hits `http://annexwyrm.localhost/`, gets
   the homepage HTML; logs in via the form; uploads a PDF; navigates
   to `/items/<id>`; sees the rating badge and review-of preamble.
2. **Apply the idiomatic split (`build-*` + `ship-activity`)
   preemptively to `emit-delete`, `emit-follow`, `emit-undo-follow`,
   `emit-like`, `emit-announce` in `src/ap/outbox.kk`.** They compile
   today but are one effect-op away from #654 again.
3. **Wire `drain-deliveries` into the serve loop.** Either a tick
   every N requests inside `serve-go` (cheap, works without threads),
   or a separate launchd agent that runs `annexwyrm drain`
   periodically. The function is ready; nothing calls it.
4. **Verify Google Drive end-to-end** with `ANNEXWYRM_E2E_GDRIVE=1
   just test-e2e-gdrive`, then cross-check with the MCP Google Drive
   `search_files` tool that the PDFs landed under `annexwyrm-test/`.
5. **Per-table typed SQL accessors.** New modules
   `src/annex/item_db.kk`, `src/ap/follow_db.kk`, etc. Each `query` /
   `exec` call site moves into a typed function. Catches column-index
   drift. NOTES.md outlines this.

## How to run e2e (the two-subagent pattern)

System-level testing is the real check. For each new e2e scenario:

1. Launch a **Product Manager subagent** (channeling Steve Jobs) and
   ask them to write the e2e *specification* — what the user should see
   on the screen at each step, what the daemon should log, what the
   database should hold. Specification, not code. Read it. Push back on
   anything vague.
2. Launch a **Programmer subagent** (channeling Phil Wadler / Conal
   Elliott — types, totality, equational reasoning) to implement the
   bash + curl test in `tests/e2e/` against the PM's spec. Insist on:
   - explicit assertions (`assert_grep`, `assert_status`) rather than
     "if it didn't crash, ship";
   - cleanup via `trap`;
   - opt-in for external services (`ANNEXWYRM_E2E_GDRIVE=1` style).

Read both outputs. Reconcile. Run. Commit only when green.

Use `/loop 1h` to keep cadence between supervision passes.

## Repo / process conventions

- `just --list` shows every recipe. Don't add a recipe outside Just.
- Nix only. No `brew install`, no `pip install`. Add to `flake.nix`.
- Two-commit-per-pull convention: one for behaviour, one for tests.
  (We violated this in the initial drop — large monorepo seed — but
  follow it going forward.)
- Commit messages explain *why*, not *what*. See `6b86396`.
- No GPG signing required (`git config commit.gpgsign` is not set
  globally); push goes through SSH key `git@github.com:cognivore/...`.

## Files worth reading first

- `NOTES.md` — the three Koka-3.2.3 quirks (genLambda, div annotations,
  C-bridge gotchas) with concrete fixes.
- `README.md` — architecture, Nix workflow, Caddy integration, design
  rules.
- `nix/annexwyrm.Caddyfile` — the music-box-shaped site config.
- `tests/e2e/run.sh` — the existing harness; mirror its structure for
  the new Caddy-fronted scenarios.
- `src/ap/outbox.kk` — the idiomatic emit-* pattern; replicate.

## Final word

The hard parts are done: Final-Tagless effect lattice, AP S2S
federation, hand-rolled JSON parser, the C bridge, the Nix flake. The
remaining work is plumbing and confidence-building. Don't get clever
where the previous CTO already got burned.
