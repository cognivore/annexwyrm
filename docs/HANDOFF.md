# annexwyrm — CTO handoff

You are taking over a **live, deployed** service. Read this entire file
before touching any code. The previous edition of this handoff described a
pre-deployment state and contained several errors, all corrected below —
trust this edition.

## What works right now (verified, not claimed)

- **`http://annexwyrm.localhost/` is live in production** on this machine:
  music-box Caddy (`com.localhost.caddy`) reverse-proxies to the daemon's
  Unix socket; the daemon runs as launchd agent
  `org.nix-community.home.annexwyrm`, deployed declaratively via
  `~/Github/nixvana/home-manager` (`services.annexwyrm` in
  `septnesis/home.nix`, mirroring `services.zensurance`).
- Login (`sweater`), styled pages, public/private PDF uploads, reviews with
  `-3..+3` ratings, cross-links, logout — all verified through the real
  Caddy→socket path, plus a human browser pass.
- The login password lives in **rageveil** at
  `annexwyrm.localhost/sweater/password` — never in the nix store. The
  launchd agent's `serveScript` resolves it with `rageveil show` at every
  (re)start and applies it via idempotent `annexwyrm init`. Rotate with
  `rageveil insert <key>` + `launchctl kickstart -k
  gui/$(id -u)/org.nix-community.home.annexwyrm`.
- **Three e2e suites** (`just --list`):
  - `test-e2e` — socket-direct: ingest, reviews, anonymous authz, plus the
    publish/unpublish federation-emission journey (61 assertions).
    Spec: `tests/e2e/SPEC-publish.md`.
  - `test-e2e-caddy` — an isolated Caddy on probed-free ports fronting a
    temp daemon; the full user journey over TCP incl. static CSS, cookie
    attributes, Via-header proxy proof (110 assertions).
    Spec: `tests/e2e/SPEC-caddy.md`.
  - `test-e2e-federation` — two live instances over S2S (landing with
    priority 3). Spec: `tests/e2e/SPEC-federation.md`.
- `src/ap/outbox.kk`: **all seven** `emit-*` functions follow the #654-safe
  `build-*` (pure, `config`-only) + `ship-*` (effects, struct as parameter)
  split and return `()`. Adversarially reviewed for behavior drift.
- **PERMANENT production is LIVE** at `https://wyrm.fere.me` (handle
  `@sweater@wyrm.fere.me`) — 24/7 on the cube box `root@chat.md110.se`
  (Ubuntu, no nix), independent of any laptop. Built NATIVELY on the server
  (official koka 3.2.3 linux-x64 in /usr/local + apt libsqlite3/ssl/curl/
  argon2), served by the `annexwyrm` systemd unit on /run/annexwyrm/sock
  behind nginx (`/etc/nginx/sites-enabled/wyrm-fere`, :443 → unix socket)
  with a certbot Let's Encrypt cert. Login password in `/etc/annexwyrm/env`
  (root 600, from rageveil). Redeploy with `./deploy.sh` (rsync → /opt/
  annexwyrm, koka build, restart) — mirrors north-london-cube-community.
  Data in `/var/lib/annexwyrm` (outside the rsync target). Porkbun A record
  `wyrm.fere.me → 46.62.199.15`.
- A second public instance also exists on the LAPTOP via tuntun at
  `https://annexwyrm.sweater.fere.me`
  (handle `@sweater@annexwyrm.sweater.fere.me`; webfinger + actor + key
  resolve over a real Let's Encrypt cert). Wired via tuntun: the module's
  `publicDomain` option flips the actor identity to https://<publicDomain>
  and adds a second Caddy site on `tunnelPort` (8730) fronting the daemon
  socket; `tuntun.nix` (`auth = "public"`) registers it (`tuntun register`).
  Session cookie gains `Secure` on the HTTPS path. NOTE: first bringup was
  blocked by the fere.me tuntun-server's stale Porkbun DNS key (server-wide
  TLS failure); restored from rageveil `porkbun.com/api` → `/var/lib/tuntun-
  secrets/` on the box (old files backed up `*.bak-20260605-2245`). If that
  key reverts on a box redeploy, no tenant subdomain gets new certs.

## Hard-won facts — get these wrong and you lose a day

1. **Canonical build = `nix build .#default`.** The dev-shell `just build`
   is broken on this darwin host: the shell's `NIX_CFLAGS_COMPILE` injects
   a mismatched `libcxx+apple-sdk-26.4 -isystem` ahead of the
   `apple-sdk-14.4` sysroot, shadowing `<time.h>` for the C bridge
   (koka's nixpkgs wrapper pins `CC=clang-wrapper-21.1.8` in BOTH paths —
   the compiler was never the difference). The e2e suites build via
   `nix build` for this reason; they also honor `ANNEXWYRM_BINARY`.
2. **annexwyrm requires koka 3.2.3 and must NOT follow nixvana's nixpkgs.**
   nixos-unstable ships koka 3.2.2, whose C codegen omits the bridge
   header includes (`time_t`/`aw_cstr` undefined → hard errors). The
   nixvana input is deliberately `annexwyrm.url = "github:cognivore/
   annexwyrm";` with **no** `inputs.nixpkgs.follows` — there is a comment
   in nixvana's flake.nix saying so. Do not "fix" it.
3. **A git-backed flake ships tracked files only.** A brand-new file that
   isn't `git add`ed is invisible to `nix build` — the failure mode is
   koka's "unable to read external file" on a file that plainly exists.
4. **Daemon logs go to stderr, flushed per line** (`csrc/log_bridge.c`).
   They used to go to stdout via `println`, which is fully buffered when
   redirected — production `daemon.log` was permanently empty and you
   could not debug a running daemon. Launchd ops read
   `~/.local/share/annexwyrm/daemon.err`.
5. **Caddyfile blocks need `{` to end the line.** The one-line
   `request_body { max_size 4GB }` is a parse error that kept Caddy from
   loading at all (it crash-looped with exit 1). `caddy validate
   --adapter caddyfile` before shipping any Caddyfile change.
6. **`init` and `serve` must run with the same identity env**
   (`ANNEXWYRM_DOMAIN/BASE_URL/USERNAME/...`). Without it, init mints the
   config_env default actor (`alice@annexwyrm.local`, https) while the
   daemon serves a different identity; login fails and `local_login`'s FK
   to `actor(id)` silently rejects the password row (`exec` return codes
   are ignored). The home-manager module's `serveScript` + shared `appEnv`
   make drift impossible — keep it that way.
7. **Static assets are served by Caddy from the package store path**
   (`${pkg}/share/annexwyrm/static`), never the data dir (nothing
   populates a data-dir static/, and the daemon has no `/static` route —
   the router's catch-all 404s).
8. **`install -m555`, not `cp`, in package.nix's installPhase** — koka's
   sandbox-emitted binary is 0644 and a bare `cp` ships a non-executable
   store path (launchd EACCES).
9. **macOS test-shell traps:** BSD awk silently ignores `IGNORECASE`
   (Caddy capitalizes `Location:`/`Via:` — parse headers with `grep -i`);
   `curl -F` treats `<`/`@` as file directives (use `--form-string` for
   literals); functions returning results via globals must not be called
   in `$( … )` command substitution (subshell + `set -u` = unbound
   variable).
10. Koka quirks live in `NOTES.md`: #654 and the build/ship idiom,
    pervasive `div` annotations, `--cclib`/`--ccincdir` semantics,
    keywords (`raw`/`pub`/`handle`), no dash-digit identifier endings.

## koka-lang/koka#654 status

Still open, no fix in `dev` (the 3.2.4–3.2.7 bumps are version-only). The
idiomatic `build-*` + `ship-*` split — now applied to every `emit-*` — is
the fix. If the issue ever lands a real fix, revisit whether the builders
can be inlined; until then, never construct a mixed raw/ref value struct
and run a multi-effect tail in the same body, and never return a
just-built value struct from an effectful function. Poll the issue
occasionally: https://github.com/koka-lang/koka/issues/654

## Priority order (updated)

1. **Land priority 3: delivery drain + federation proof.** The wiring
   (poll-timeout `accept` + `tick` callback in `serve-loop`, `annexwyrm
   drain` CLI) and the two-instance federation e2e. Until this is green,
   annexwyrm is an excellent local archive and an unproven fediverse
   citizen: activities queue in `delivery` and go nowhere.
2. **Re-deploy production** after p3 (relock the nixvana input +
   `home-manager switch` + kick Caddy and the agent) — the deployed binary
   predates the stderr-log fix and the outbox refactor.
3. **Outbound remote-actor fetch.** `emit-follow` assumes the target's
   inbox is already cached in `actor`; nothing populates it for outbound
   follows of never-seen actors (the federation e2e documents the seam).
   Wire webfinger + actor fetch into the follow path.
4. **Google Drive e2e** (`ANNEXWYRM_E2E_GDRIVE=1 just test-e2e-gdrive`) —
   still never run against the real `gdrive` rclone remote.
5. **Per-table typed SQL accessors** (`src/annex/item_db.kk`, …) — the
   column-index-drift protection NOTES.md outlines. Not started.

## Process conventions (unchanged, plus what's now established)

- `just --list` is the catalog. Nix only — no brew/pip. Two commits per
  change: behaviour, then tests. Messages explain *why* (see `92b159b`,
  `08a621d`). Push to `origin/main` over SSH.
- **E2e is spec-first, two-subagent:** a product-manager pass writes the
  normative spec (`tests/e2e/SPEC-*.md` — three exist; match their
  rigor: every step asserts (a) what the client sees, (b) what the daemon
  logs, (c) what the DB holds), then an engineer implements against it,
  then the supervisor runs, reconciles, and commits only when green.
  This pattern has caught a real production bug every time it ran.
- Adversarially review refactors (instruct the reviewer to *refute*).
  The reviewer's "I cannot refute, and here is what convinced me" is the
  bar.

## Final word

The hard parts remain done — the effect lattice, the AP domain, the C
bridge, the Nix plumbing — and the service is now actually deployed and
guarded by 171+ assertions. The remaining work is making federation real
(priorities 1–3 above) and the confidence-building around it. The
previous edition of this file warned: don't get clever where your
predecessor got burned. Amendment from the field: the burns were all in
the gap between "compiles" and "serves a styled page to a human through
the real proxy" — keep the e2e suites merciless and that gap stays
closed.
