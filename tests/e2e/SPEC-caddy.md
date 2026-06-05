# SPEC — Caddy-fronted end-to-end test for annexwyrm

**File to produce:** `tests/e2e/run-caddy.sh` (+ any TCP helpers added to a new `tests/e2e/lib-caddy.sh` or inlined).
**Audience:** the engineer who writes the test.
**Status of this document:** normative. Every "MUST" below is a hard assertion the test is required to make. "If it didn't crash, ship it" is forbidden. Each step asserts an exact, observable fact.

---

## 0. Why this test exists (read before writing a line)

The existing `tests/e2e/run.sh` talks **directly** to the daemon's Unix socket. It never starts Caddy. That blind spot shipped six production bugs. Four of them are *only* observable through a reverse proxy:

| # | Bug | The assertion in this spec that catches it |
|---|-----|--------------------------------------------|
| 2 | CSS 404'd — Caddy served `/static` from an empty dir instead of `${pkg}/share/annexwyrm/static`. | Step 4: `GET /static/style.css` MUST be `200` + `Content-Type: text/css`. |
| 3 | Generated Caddyfile invalid — `request_body { max_size 4GB }` on one line is a parse error. | Step 2: `caddy validate` MUST exit `0`; the Caddyfile this test writes MUST use the multi-line block form. |
| 4 | Actor minted with the wrong identity (init ran without `ANNEXWYRM_*`), so login's FK to `actor(id)` silently dropped the password row. | Step 3: `local_login` row MUST exist AND `actor.id`/`actor.username`/`actor.domain` MUST equal the served identity; Step 6: login MUST succeed. |
| 6 | Session cookie carried `Secure` over `http://` dev, so the browser dropped it and login appeared to "work" but no session stuck. | Step 6: `Set-Cookie` MUST NOT contain `Secure` (case-insensitive). |

Bugs #1 (binary mode 0644) and #5 (`just build` broken on this host) are handled by reusing `run.sh`'s build path verbatim (`nix build .#default`, honoring `ANNEXWYRM_BINARY`); this test inherits that and additionally asserts the binary is executable.

This test is the gate that says: *a real human hitting `http://annexwyrm.localhost` sees a styled, working archive.* If any assertion below regresses, we do not ship.

---

## 1. Scope and non-goals

**In scope (the complete user journey, end to end, through Caddy):**

1. Build/locate the canonical binary; assert it is executable.
2. Generate an **isolated** Caddyfile and `caddy validate` it.
3. `init` a fresh data dir with the *exact* served identity; assert DB state.
4. Start the daemon on a temp Unix socket; start Caddy on a temp TCP port reverse-proxying to that socket.
5. Homepage loads through Caddy **and is styled** (CSS 200, `text/css`).
6. Every request demonstrably flows through Caddy (assert the `Via` header).
7. Form login sets a session cookie that is **not** `Secure`; the session lands in the DB.
8. A wrong password is rejected and sets **no** session.
9. Upload a public PDF and a private PDF (multipart, through Caddy).
10. Upload a review with a non-empty `in_reply_to` that renders the "review of \<hyperlinked URL\>" preamble, a rating badge, and stars.
11. The item page renders correctly.
12. Logout clears the cookie and deletes the session row.
13. Anonymous browsing sees the public item (200) but **not** the private one (404).

**Out of scope:** TLS/HTTPS (this is the `http://` dev path by design — that is exactly where bug #6 lived), HTTP/2/3, ActivityPub federation delivery, Google Drive sync, multi-actor.

**Isolation is mandatory.** This test MUST NOT touch the developer's running music-box Caddy, `~/Caddy/`, the launchd agent, or `~/.local/share/annexwyrm`. It runs its **own** Caddy process with its **own** config, on a **temp** port, against a **temp** socket and data dir, and tears all of it down on exit. A developer with the production service running must be able to run this test with zero interference.

---

## 2. Environment, invocation, and knobs

- Runs **inside the Nix dev shell** (`nix develop`), which provides `caddy`, `curl`, `python3`, `nc` (netcat), `sqlite3`, `jq`. No installs.
- `set -euo pipefail`. A single `trap cleanup EXIT INT TERM` MUST kill the daemon **and** Caddy and `rm -rf` the temp dir (unless `KEEP_TMP=1`, which leaves it and prints the path, mirroring `run.sh`).
- **Binary resolution MUST mirror `run.sh` exactly:** if `ANNEXWYRM_BINARY` is set, use it; else `nix build .#default --out-link "$REPO/result"` and use `$REPO/result/bin/annexwyrm`. Then assert `[ -x "$BINARY" ]` (catches bug #1) — fail loudly if not.
- **Static dir derivation MUST mirror the home-manager module:** the package's static directory is
  `STATIC_DIR="$(dirname "$(dirname "$BINARY")")/share/annexwyrm/static"`
  (i.e. from `…/bin/annexwyrm` → `…/share/annexwyrm/static`). Assert `[ -f "$STATIC_DIR/style.css" ]` before starting Caddy — if the package didn't install the CSS, fail here with a clear message rather than discovering it via a 404 later.
- **Identity is fixed once and reused everywhere.** Define these as shell vars and pass the *same* values to `init`, to `serve`, and into every assertion:
  - `DOMAIN="annexwyrm.localhost"`
  - `USERNAME="sweater"`  ← deliberately **not** `alice`; bug #4 was exactly the mismatch between the init-default actor and the served actor. Using a non-default username here means a regression of #4 (init ignoring env) fails this test.
  - `INSTANCE_NAME="sweater's annexwyrm (caddy e2e)"`
  - `BASE_URL="http://annexwyrm.localhost"`  ← **note:** no port. See §3.4.
  - `TEST_PASS="caddy-e2e-pass"`
- **Port selection:** pick a free ephemeral TCP port on `127.0.0.1` (e.g. bind a socket via `python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'`), call it `CADDY_PORT`. Do not hardcode 80/443/2015.
- **Host header:** because we hit `http://127.0.0.1:$CADDY_PORT` but the Caddy site block is keyed on `annexwyrm.localhost`, every `curl` MUST send `-H "Host: annexwyrm.localhost"`. Helpers below bake this in.

---

## 3. Setup steps, with their three observable truths

For each step: **(a)** what the user/client sees, **(b)** what the daemon should log, **(c)** what the DB should hold.

### Step 1 — Build / locate the binary

- **(a)** `$BINARY` exists and `[ -x "$BINARY" ]` is true. (Catches bug #1.)
- **(b)** n/a.
- **(c)** n/a.

### Step 2 — Generate an isolated Caddyfile and validate it (catches bug #3)

Write `$TMP/Caddyfile` whose site block mirrors the **production** `nix/home-manager-module.nix` shape, parameterized for the test:

- Site address: `http://annexwyrm.localhost:$CADDY_PORT` (explicit `http://` so Caddy does **not** try ACME/TLS — the bug-#6 path).
- A `request_body` block in the **multi-line** form, exactly:
  ```
  request_body {
      max_size 4GB
  }
  ```
  The test MUST write it multi-line. Writing it as `request_body { max_size 4GB }` on one line is the regression we are guarding against; the spec forbids the one-line form.
- `reverse_proxy unix/$SOCK { … }` with `header_up X-Forwarded-Host {host}`, `header_up X-Forwarded-Proto {scheme}`, and the `transport http { versions 1.1 … }` block — same as the module.
- `handle_path /static/* { root * $STATIC_DIR\n file_server }` pointing at the **package** static dir derived in §2 (catches bug #2). It MUST NOT point at the data dir.
- A `log { output file $TMP/caddy.log … }` block so failures are debuggable.

**Assertions:**
- **(a)** `caddy validate --config "$TMP/Caddyfile" --adapter caddyfile` MUST exit `0`. On non-zero, print the Caddyfile and Caddy's stderr and fail. This single assertion is the entire defense against bug #3.
- **(b)** n/a (Caddy not yet running).
- **(c)** n/a.

### Step 3 — `init` the data dir with the served identity (catches bug #4)

Run `init` with the **full** identity env:

```
ANNEXWYRM_DOMAIN="$DOMAIN" ANNEXWYRM_BASE_URL="$BASE_URL" \
ANNEXWYRM_USERNAME="$USERNAME" ANNEXWYRM_INSTANCE_NAME="$INSTANCE_NAME" \
ANNEXWYRM_PASSWORD="$TEST_PASS" ANNEXWYRM_DATA="$DATA" \
  "$BINARY" init "$DATA"
```

**Assertions (all against `$DATA/annexwyrm.db` via `sqlite3`):**
- **(a)** `init` exits `0`.
- **(b)** n/a (one-shot command; its stderr may be captured but is not asserted here).
- **(c)** The DB MUST hold exactly the served identity. Assert each, individually, with an explicit failure message:
  - `SELECT count(*) FROM actor WHERE local=1;` MUST be `1`.
  - `SELECT username FROM actor WHERE local=1;` MUST equal `sweater` (catches bug #4's wrong-username default `alice`).
  - `SELECT domain FROM actor WHERE local=1;` MUST equal `annexwyrm.localhost` (catches the `annexwyrm.local` default).
  - `SELECT id FROM actor WHERE local=1;` MUST equal `http://annexwyrm.localhost/users/sweater` (catches the `https` default — bug #4 noted the default minted `https`).
  - `SELECT count(*) FROM local_login;` MUST be `1`.
  - **The FK MUST actually join** (this is the silent-drop bug): `SELECT count(*) FROM local_login l JOIN actor a ON a.id = l.actor_id WHERE a.local=1;` MUST be `1`. A bare "login row exists" check is insufficient — assert the join, because bug #4's symptom was a `local_login` row whose `actor_id` pointed at a non-existent actor.
- **Idempotency:** run `init` a second time; it MUST exit `0` and the four counts above MUST be unchanged (still `1`/`1`/`1`).

### Step 4 — Start the daemon, then Caddy; confirm both are live

Start the daemon with the **same** identity env (minus `ANNEXWYRM_PASSWORD`, matching `run.sh` and the module's `serve`), `> $TMP/daemon.log 2>&1 &`, capture PID.

```
ANNEXWYRM_DOMAIN="$DOMAIN" ANNEXWYRM_BASE_URL="$BASE_URL" \
ANNEXWYRM_USERNAME="$USERNAME" ANNEXWYRM_INSTANCE_NAME="$INSTANCE_NAME" \
ANNEXWYRM_SOCKET="$SOCK" ANNEXWYRM_DATA="$DATA" \
  "$BINARY" serve > "$TMP/daemon.log" 2>&1 &
```

- Reuse `wait_for_socket "$SOCK" 10` from `lib.sh`, then the same "actually speaks HTTP over the socket" retry loop `run.sh` uses (curl `--unix-socket`).
- Start Caddy: `caddy run --config "$TMP/Caddyfile" --adapter caddyfile > $TMP/caddy.run.log 2>&1 &`, capture PID.
- **Wait for Caddy** with a bounded poll loop (NOT a foreground `sleep`): loop up to ~10s calling the TCP curl helper against `/`, breaking when it returns any HTTP status. If it never does, dump `$TMP/caddy.run.log`, `$TMP/caddy.log`, and `$TMP/daemon.log`, then fail.

**Assertions:**
- **(a)** Within the timeout, `GET http://127.0.0.1:$CADDY_PORT/` (Host: annexwyrm.localhost) returns an HTTP status (not a connection refused).
- **(b)** `$TMP/daemon.log` MUST show the daemon bound its socket (e.g. a startup line; assert the log is non-empty and contains no `panic`/`internal error`/`EACCES`). At minimum: assert the daemon process is still alive (`kill -0 $DAEMON_PID`) — a daemon that died on launch (bug #1's EACCES) fails here.
- **(c)** n/a.

### Step 4.1 — TCP helpers (the macOS-correct ones)

The test MUST define Caddy-fronted (TCP) variants of the helpers, because `lib.sh`'s assume a Unix socket. Requirements:

- A base curl wrapper: `caddy_curl() { curl --silent --show-error -H "Host: annexwyrm.localhost" "$@"; }` where the URL passed is `http://127.0.0.1:$CADDY_PORT…`.
- **Header parsing MUST be case-insensitive and tolerant of Caddy's capitalization.** Caddy emits `Location:` (capitalized) and adds `Via: 1.1 Caddy`. BSD `awk` has **no** `IGNORECASE`. Therefore the test MUST parse headers with `grep -i` (or lowercase the header dump first with `tr '[:upper:]' '[:lower:]'`), **not** the `awk 'BEGIN{IGNORECASE=1}'` trick in `lib.sh`'s `upload` (that trick is a no-op on BSD awk and will miss the Location header). Strip trailing `\r` from any captured header value.
- **Multipart fields:** mirror `lib.sh`'s discipline — `--form-string` for every literal field (so `<` and `@` in HTML content/titles are not interpreted), and `-F file=@PATH` only for the file. Carry the cookie jar with `--cookie`/`--cookie-jar`.
- A status helper: `assert_status_tcp PATH EXPECTED` using `--write-out '%{http_code}'` against the Caddy URL with the Host header.
- A header-dump helper that returns the full response headers for `Set-Cookie`, `Via`, `Content-Type`, `Location` assertions.

### Step 5 — Homepage loads, is styled, and goes through Caddy (catches #2 and proves #6's transport)

Three separate requests; assert all.

**5a. Homepage HTML.** `GET /` (anon).
- **(a)** Status `200`. `Content-Type: text/html; charset=utf-8` (assert the exact string, case-insensitively on the header name). Body MUST contain:
  - `<link rel="stylesheet" href="/static/style.css">` (the stylesheet *reference* — proves the page asks for CSS),
  - the instance name `sweater&#39;s annexwyrm (caddy e2e)` — note the apostrophe is HTML-escaped to `&#39;` by `esc`, so assert the escaped form (this also proves the served `ANNEXWYRM_INSTANCE_NAME` reached the renderer, reinforcing #4),
  - `<a href="/">annexwyrm</a>` (the brand chrome from `layout`),
  - on a fresh archive, `nothing public yet.` (the empty-state marker from `home.kk`). This proves the DB is genuinely empty *before* uploads — a clean baseline.
- **(b)** Daemon log SHOULD record handling the request. Not strictly asserted in 5a (the renderer is pure), but the daemon MUST still be alive after.
- **(c)** `SELECT count(*) FROM item;` MUST be `0` at this point.

**5b. CSS is served, by Caddy, as CSS (THE bug-#2 assertion).** `GET /static/style.css` (anon).
- **(a)** Status MUST be `200` (not 404). `Content-Type` MUST match `text/css` (assert with `grep -i 'content-type:.*text/css'`). Body MUST contain a known CSS marker from the real file, e.g. `--bg:        #f3eed9;` or the literal token `.rating` — assert a substring that exists in `static/style.css` so a wrong-but-200 file (e.g. an HTML 404 page returned with 200) still fails. This is the single most important assertion in the suite; it is the bug that motivated the whole test.
- **(b)** The daemon log MUST **NOT** mention `/static/style.css` at all — Caddy serves it directly and the daemon has no `/static` route. (Optional but recommended: `grep -vq '/static/style.css' "$TMP/daemon.log"` after this request, to prove the asset never hit the Koka process. If the daemon *did* see it, either routing changed or Caddy isn't fronting static — both are regressions.)
- **(c)** n/a.

**5c. The request flowed through Caddy (the `Via` proof).** Re-fetch `/` (or reuse 5a's header dump).
- **(a)** Response headers MUST contain `Via: 1.1 Caddy` (assert `grep -i '^via:.*caddy'`). This is the unforgeable proof we are testing the proxied path and not accidentally hitting the socket. Every subsequent assertion in this suite inherits this guarantee because it uses the same TCP helper.
- **(b)** n/a.
- **(c)** n/a.

### Step 6 — Login via the form; cookie MUST NOT be `Secure` (catches #6)

`POST /login` with `application/x-www-form-urlencoded` body `username=sweater&password=caddy-e2e-pass` (use `--data-urlencode`), through Caddy, saving headers and cookie jar. Do **not** follow redirects (`-L` off) so we can inspect the 303 + `Set-Cookie` directly.

**Assertions:**
- **(a)**
  - Status MUST be `303` (`see-other("/")` → 303 See Other).
  - `Location` header MUST be `/` (parsed case-insensitively — Caddy capitalizes it).
  - A `Set-Cookie` header MUST be present and MUST start with `session=` followed by a non-empty token.
  - The `Set-Cookie` value MUST contain `HttpOnly`, `Path=/`, `SameSite=Lax`, `Max-Age=1209600`.
  - **The `Set-Cookie` value MUST NOT contain `Secure`** — assert `! grep -i 'secure'` on the cookie line. This is the bug-#6 assertion. A `Secure` cookie over `http://` is silently dropped by browsers, breaking login while every server-side check looks fine.
- **(b)** Daemon log: login succeeded (no `invalid credentials` rendered). Indirectly verified by the 303 + cookie (the handler only emits 303/Set-Cookie on a successful argon2 verify; the failure path returns 200 with the re-rendered form). Assert the response was 303, not 200 — a 200 here means auth failed.
- **(c)** A new row in `session`: `SELECT count(*) FROM session;` MUST be `1`, and the token MUST match the cookie value:
  - extract the token from the `Set-Cookie` header,
  - `SELECT count(*) FROM session WHERE token = '<tok>';` MUST be `1`,
  - `SELECT count(*) FROM session s JOIN actor a ON a.id = s.actor_id WHERE a.username='sweater';` MUST be `1` (the session belongs to the right actor — re-proves identity coherence from #4).

### Step 7 — Wrong password is rejected, sets no session

Fresh request (no jar, or a throwaway jar): `POST /login` with `username=sweater&password=WRONG`.

**Assertions:**
- **(a)** Status MUST be `200` (the handler re-renders the form on failure, it does **not** redirect). Body MUST contain `invalid credentials` (the exact error string from `handle-login-post`) inside `<p class="err">`. There MUST be **no** `Set-Cookie: session=` with a token (assert no `Set-Cookie` line that sets a non-empty `session=`).
- **(b)** Daemon log: a failed login. Not asserted by string, but the 200 + `invalid credentials` body is the contract.
- **(c)** `SELECT count(*) FROM session;` MUST still be `1` (unchanged from Step 6 — the bad attempt created no session).

### Step 8 — Upload the public PDF (multipart through Caddy)

Generate PDFs with the existing `tests/e2e/make-pdf.py` (two distinct ones, public/private). Upload the public one as a logged-in user (Step 6's jar), via the TCP multipart helper, **not** following redirects.

Form fields (mirror `run.sh`'s `upload`): `file=@public.pdf` (`-F`), and `--form-string` for `name=Public PDF`, `summary=`, `content=<p>A document we want everyone to see.</p>`, `privacy=public`, `rating=99` (unrated), `in_reply_to=`.

**Assertions:**
- **(a)** Status MUST be `303`. `Location` header MUST match `^/items/[0-9a-f]+$` (parsed case-insensitively). Capture it as `PUBLIC_PATH`; `PUBLIC_URL="http://annexwyrm.localhost$PUBLIC_PATH"` (this is what `in_reply_to` will reference — it MUST equal the item's stored `id` so the review hyperlink resolves; see §3.4). Response MUST carry `Via: …Caddy`.
- **(b)** Daemon log MUST contain the upload-done line. The handler logs `info("upload/done", [("id", id), ("size", …), ("remotes", "0")])`, rendered by `log_console` as `[INFO] upload/done id=… size=… remotes=0`. Assert `grep` for `upload/done` and that the logged `id=` equals `$PUBLIC_URL`. (This proves the body streamed through Caddy intact and the daemon ingested it — the regression target for any future `request_body`/buffering change.)
- **(c)** `SELECT count(*) FROM item WHERE privacy='public';` MUST be `1`. `SELECT id FROM item WHERE name='Public PDF';` MUST equal `$PUBLIC_URL`. `SELECT media_type FROM item WHERE name='Public PDF';` MUST be `application/pdf`. `SELECT byte_size > 0` MUST be true.

### Step 9 — Upload the private PDF

Same as Step 8 with `privacy=private`, `name=Private PDF`, `content=<p>This stays with sweater.</p>`. Capture `PRIVATE_PATH` / `PRIVATE_URL`.

**Assertions:**
- **(a)** Status `303`, `Location` matches `^/items/[0-9a-f]+$`, `Via` present.
- **(b)** A second `upload/done` line, `id=$PRIVATE_URL`.
- **(c)** `SELECT privacy FROM item WHERE name='Private PDF';` MUST be `private`. `SELECT count(*) FROM item;` MUST now be `2`.

### Step 10 — Upload a review (non-empty `in_reply_to`) of the public PDF, rating +2

Upload (logged in) referencing the public item. Mirror `run.sh`'s review A: reuse the public PDF as the file, `name=Review: praise public PDF`, `content=<p>Praise public PDF. A perfectly reasonable read.</p>`, `privacy=public`, `rating=2`, `in_reply_to=$PUBLIC_URL`. Capture `REVIEW_A_PATH`.

**Assertions:**
- **(a)** Status `303`; capture `REVIEW_A_PATH`.
- **(b)** A third `upload/done` line.
- **(c)** `SELECT rating FROM item WHERE name LIKE 'Review: praise public%';` MUST be `2`. `SELECT in_reply_to FROM item WHERE name LIKE 'Review: praise public%';` MUST equal `$PUBLIC_URL`.

### Step 11 — Upload a review of the private PDF, rating +3, with a hyperlink in the body

Mirror `run.sh`'s review B: `name=Review: praise private PDF even more`, `content=<p>Praise private PDF <em>even more</em> — it builds upon the ideas from <a href="$PRIVATE_URL">privatePDF</a>.</p>`, `privacy=public`, `rating=3`, `in_reply_to=$PRIVATE_URL`. Capture `REVIEW_B_PATH`.

**Assertions:**
- **(a)** Status `303`; capture `REVIEW_B_PATH`.
- **(b)** A fourth `upload/done` line.
- **(c)** `SELECT rating FROM item WHERE name LIKE 'Review: praise private%';` MUST be `3`. `SELECT in_reply_to …` MUST equal `$PRIVATE_URL`. `SELECT count(*) FROM item;` MUST now be `4`.

### Step 12 — The review item page renders correctly (preamble + badge + stars + hyperlink)

`GET $REVIEW_B_PATH` (anon — the review itself is public).

**Assertions (a):** Status `200`, `Content-Type: text/html; charset=utf-8`, `Via` present. The body MUST contain, each asserted separately:
- The **"review of" preamble with a hyperlinked URL** (from `review-of-block`):
  `<p class="review-of">review of <a href="http://annexwyrm.localhost/items/` — assert the literal preamble class `class="review-of"`, the words `review of`, and that the href equals `$PRIVATE_URL` (the in-reply-to target). This is the exact feature the prompt calls out; assert the whole shape, not just the words "review of".
- The **rating badge** (from `rating-badge`): `<span class="rating positive">` and the literal text `[+3]` (from `rating-show`). Assert both the CSS class `rating positive` and the badge `[+3]`.
- The **stars** (from `rating-stars`): `★★★` (three filled stars). Assert the exact glyph run `★★★`.
- The **author hyperlink in the body content** survives verbatim (HTML content is rendered raw inside `<section class="content">`): `href="http://annexwyrm.localhost/items/…">privatePDF</a>` — assert the body contains `>privatePDF</a>` and the `href="$PRIVATE_URL"`. This proves the multipart `--form-string` path preserved `<` and `@` (the macOS curl gotcha) end to end through Caddy.

Also `GET $REVIEW_A_PATH` (anon):
- Status `200`; body MUST contain `<span class="rating positive">`, `[+2]`, and exactly `★★` (two stars), and `href="$PUBLIC_URL"` in the preamble.

**(b)** n/a (render is pure; daemon stays alive). **(c)** n/a.

### Step 13 — Homepage now lists the reviews with badges

`GET /` (anon). The home list (`home.kk`) is rendered from a separate code path than the item page, so assert it independently.

**Assertions (a):** Status `200`. Body MUST contain:
- `Review: praise public PDF` and `Review: praise private PDF even more` (both review titles).
- `[+2]` and `[+3]` (badges from `row-rating`/`rating-show-pure`).
- `class="rating positive"` (the positive-rating CSS hook).
- `[review]` marker (`home.kk` appends `<span class="meta">[review]</span>` when `in-reply-to != ""`) — assert it appears for the reviews.
- The empty-state string `nothing public yet.` MUST **NOT** appear anymore (the archive is no longer empty).

**(c)** `SELECT count(*) FROM item WHERE privacy='public';` MUST be `3` (public PDF + two public reviews).

### Step 14 — Logout clears the cookie and deletes the session

`POST /logout` carrying Step 6's session cookie, not following redirects.

**Assertions:**
- **(a)** Status `303`, `Location: /`. `Set-Cookie` MUST be present and MUST set `session=` to **empty** with `Max-Age=0` (the expiry form from `handle-logout`), `Path=/`, `HttpOnly`, `SameSite=Lax`, and again **NOT** `Secure`. `Via` present.
- **(b)** n/a.
- **(c)** `SELECT count(*) FROM session;` MUST be `0` (the row was deleted by `DELETE FROM session WHERE token = ?`).
- **Follow-up:** an authenticated-only action with the now-stale jar MUST be refused: `GET /upload` MUST return `403` (`handle-upload-form` → `forbidden("login required")`), body containing `login required`. This proves logout actually invalidated the session, not just rewrote a cookie.

### Step 15 — Anonymous browsing: public visible (200), private hidden (404)

Using **no** cookie jar (a brand-new anonymous client), through Caddy:

**Assertions:**
- **(a)** `assert_status_tcp "$PUBLIC_PATH" 200` — the public item is reachable anonymously.
- **(a)** `assert_status_tcp "$PRIVATE_PATH" 404` — the private item is **not found** (not 403; the handler deliberately returns `not-found("no such item")` for private items to an anon visitor, to avoid leaking existence). Assert exactly `404`, and assert the body contains `no such item` (and MUST NOT contain `Private PDF` or the private content — no information leak).
- **(b)** n/a.
- **(c)** The DB still holds the private item (`SELECT count(*) FROM item WHERE privacy='private';` MUST be `1`) — proving the 404 is an **authorization** decision, not data loss.

---

## 3.4. The base-URL / port coherence requirement (do not skip)

Item `id`s are minted as `get-base-url() ++ "/items/" ++ slug`, i.e. from `ANNEXWYRM_BASE_URL`. We set `ANNEXWYRM_BASE_URL=http://annexwyrm.localhost` (no port). Therefore:

- `PUBLIC_URL`/`PRIVATE_URL` (the values we pass as `in_reply_to` and assert in hrefs) MUST be built as `http://annexwyrm.localhost$PATH` — **matching `BASE_URL`, not** `http://127.0.0.1:$CADDY_PORT`. The `Location` header returns a **path** (`/items/<slug>`), and we hit Caddy by IP+port with a `Host:` header, but the stored/rendered `id` uses the base URL. Keep these two straight or the `in_reply_to` href assertions in Step 12 will not match.
- When we *fetch* `$PUBLIC_PATH`/`$REVIEW_B_PATH`, we use the **path** against `http://127.0.0.1:$CADDY_PORT` + `Host: annexwyrm.localhost`. We never fetch the absolute `…localhost…` URL directly (it would not resolve to our test port).

This split (base-URL for identity, IP:port+Host for transport) is the single subtlest thing in the test. Call it out in a comment.

---

## 4. Failure ergonomics (non-negotiable)

- Every assertion failure MUST print: what was expected, what was observed, and the relevant context (the response body's first ~40 lines, or the failing SQL and its result). Reuse `lib.sh`'s `assert_*` message style.
- On **any** failure or early exit, the trap MUST dump `$TMP/daemon.log` and `$TMP/caddy.run.log` (and `$TMP/caddy.log` if non-empty) to stderr before cleanup, so CI logs are self-contained.
- Cleanup MUST kill **both** the daemon and Caddy (track both PIDs) and `wait` on them, then remove `$TMP`. A leaked Caddy on a temp port is a test bug.
- `KEEP_TMP=1` leaves the temp dir and prints its path (mirror `run.sh`).

## 5. Definition of done

The test passes **iff** every MUST above holds. In particular, the suite is considered to have *earned its place* only if, when reverted against the four historical bugs, it fails:

- Point Caddy's `/static` `root` at the empty data dir → Step 5b MUST fail.
- Collapse `request_body` to one line → Step 2 (`caddy validate`) MUST fail.
- Run `init` without the identity env → Step 3 (username/domain/FK-join) MUST fail.
- Append `; Secure` to the login `Set-Cookie` → Step 6 MUST fail.

If any of those four sabotages does **not** turn the suite red, the test does not meet this spec.

---

## Appendix A — exact strings the test asserts (copy targets)

| Where | Literal to assert (substring) |
|---|---|
| Homepage CSS link | `<link rel="stylesheet" href="/static/style.css">` |
| Homepage brand | `<a href="/">annexwyrm</a>` |
| Homepage instance name (escaped) | `sweater&#39;s annexwyrm (caddy e2e)` |
| Empty archive | `nothing public yet.` |
| CSS content marker | `--bg:        #f3eed9;` (or `.rating`) |
| CSS content-type | `text/css` |
| HTML content-type | `text/html; charset=utf-8` |
| Caddy proxy proof | `Via: 1.1 Caddy` (match `grep -i '^via:.*caddy'`) |
| Login success | `303` + `Location: /` + `Set-Cookie: session=<tok>; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600` |
| Login cookie forbidden attr | `Secure` MUST be absent |
| Login failure | `200` + `invalid credentials` (+ `class="err"`) |
| Upload redirect | `Location: /items/<hex>` (`^/items/[0-9a-f]+$`) |
| Upload log line | `upload/done id=http://annexwyrm.localhost/items/<hex>` |
| Review preamble | `<p class="review-of">review of <a href="$IN_REPLY_TO">` |
| Rating badge +3 | `<span class="rating positive">` + `[+3]` |
| Stars +3 / +2 | `★★★` / `★★` |
| Home review marker | `[review]` |
| Private to anon | `404` + `no such item`, and NOT `Private PDF` |
| Logout cookie | `session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`, no `Secure` |
| Logged-out upload | `403` + `login required` |

## Appendix B — macOS / BSD pitfalls (the test author WILL hit these)

1. **No `awk` `IGNORECASE`.** Parse all headers with `grep -i` or lowercase first. The `awk 'BEGIN{IGNORECASE=1}'` in `lib.sh`'s `upload` is a silent no-op on BSD awk and would miss Caddy's capitalized `Location:`. Do not copy it.
2. **`curl -F` interprets `<` and `@`.** Use `--form-string` for every literal field; `-F file=@…` only for the file. (HTML content has both `<` and, in URLs, no `@`, but titles/content with `<p>` would be mangled by `-F`.)
3. **`Via` and `Location` are added/capitalized by Caddy** — they will not appear when talking to the socket directly; their presence is the proof we're proxied.
4. **No foreground `sleep` for readiness** — poll in a bounded loop (curl-until-status / `nc -z`), matching the harness conventions.
5. **`Host:` header is mandatory** on every request because we connect by `127.0.0.1:PORT` but the site block is keyed on `annexwyrm.localhost`.
