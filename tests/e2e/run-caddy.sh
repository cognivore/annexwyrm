#!/usr/bin/env bash
# tests/e2e/run-caddy.sh — Caddy-fronted end-to-end test for annexwyrm.
#
# WHY THIS EXISTS
# ---------------
# tests/e2e/run.sh talks DIRECTLY to the daemon's Unix socket and never
# starts Caddy. That blind spot shipped six production bugs; four of them are
# only observable through a reverse proxy:
#
#   #2  CSS 404'd — Caddy served /static from an empty dir instead of the
#       package's read-only ${pkg}/share/annexwyrm/static.   → Step 5b
#   #3  Generated Caddyfile invalid — `request_body { max_size 4GB }` on one
#       line is a parse error; the block must be multi-line.  → Step 2
#   #4  Actor minted with the wrong identity because init ran without the
#       ANNEXWYRM_* env, so login's FK to actor(id) silently dropped the
#       password row.                                          → Steps 3 & 6
#   #6  Session cookie carried `Secure` over http:// dev, so browsers dropped
#       it and login appeared to work but no session stuck.    → Step 6
#
# Bugs #1 (binary mode 0644) and #5 (dev-shell `just build` broken on this
# darwin host) are inherited from run.sh's build path: `nix build .#default`
# (honoring ANNEXWYRM_BINARY) plus an explicit `[ -x ]` assertion.
#
# This test runs its OWN isolated Caddy on a probed-free TCP port against a
# temp socket + temp data dir, and tears all of it down on exit. It MUST NOT
# touch the developer's running music-box Caddy, ~/Caddy/, the launchd agent,
# or ~/.local/share/annexwyrm.
#
# Usage:
#     just test-e2e-caddy
#     KEEP_TMP=1 just test-e2e-caddy        # leave the temp dir for inspection
#     ANNEXWYRM_BINARY=/path just test-e2e-caddy

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/../.." && pwd)"

# shellcheck source=./lib.sh
. "$THIS_DIR/lib.sh"

# ===========================================================================
#  Fixed identity (set once, reused for init, serve, and every assertion).
#
#  USERNAME is deliberately NOT `alice` and DOMAIN is `annexwyrm.localhost`
#  (not `annexwyrm.local`), and BASE_URL is http:// (not https://): these are
#  exactly the three config_env defaults that bug #4 silently fell back to
#  when init ran without the env. Using non-default values means a regression
#  of #4 (init ignoring the env) fails Step 3 loudly.
# ===========================================================================
DOMAIN="annexwyrm.localhost"
USERNAME="sweater"
INSTANCE_NAME="sweater's annexwyrm (caddy e2e)"
BASE_URL="http://annexwyrm.localhost"      # NOTE: no port — see §3.4 below.
TEST_PASS="caddy-e2e-pass"

# ---------------------------------------------------------------------------
#  §3.4 base-URL / port coherence (the subtlest thing in this test)
#
#  Item ids are minted as `${BASE_URL}/items/<slug>`, i.e. from
#  ANNEXWYRM_BASE_URL (= http://annexwyrm.localhost, NO port). The Location
#  header on upload returns a *path* (/items/<slug>). We therefore keep two
#  worlds straight:
#
#    * IDENTITY  (in_reply_to values, stored ids, rendered hrefs, log lines):
#        http://annexwyrm.localhost/items/<slug>     ← uses BASE_URL
#    * TRANSPORT (how we actually reach Caddy):
#        http://127.0.0.1:$CADDY_PORT<path>  +  Host: annexwyrm.localhost
#
#  We never fetch the absolute identity URL directly — it would not resolve to
#  our test port. We fetch PATHS against CADDY_BASE with the Host header.
# ---------------------------------------------------------------------------

# ===========================================================================
#  Temp layout + free-port probe.
# ===========================================================================
TMP="$(mktemp -d -t annexwyrm-caddy-e2e.XXXXXX)"
DATA="$TMP/data"
SOCK="$TMP/sock"
DAEMON_LOG="$TMP/daemon.log"
CADDYFILE="$TMP/Caddyfile"
CADDY_RUN_LOG="$TMP/caddy.run.log"
CADDY_ACCESS_LOG="$TMP/caddy.log"
JAR="$TMP/cookies"

# Hermetic blob backends (local-backend temp dirs) + the public-URL seam.
# rclone treats a plain absolute path as the local backend, so real bytes
# land in these dirs and blob-public-url returns the constructed URL.
ARCHIVE_REMOTE="$TMP/archive"
PUBLIC_REMOTE="$TMP/public"
PUBLIC_URL_BASE="http://example.test/dl"
mkdir -p "$ARCHIVE_REMOTE" "$PUBLIC_REMOTE"

# Probe two free ephemeral TCP ports on 127.0.0.1: one for the site, one for
# Caddy's admin endpoint (so we never collide with the user's Caddy admin on
# :2019). We DO NOT hardcode 80/443/2015/2019.
free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}
CADDY_PORT="$(free_port)"
CADDY_ADMIN_PORT="$(free_port)"

# Exported for the TCP helpers in lib.sh.
export CADDY_BASE="http://127.0.0.1:${CADDY_PORT}"
export CADDY_HOST="${DOMAIN}"

note "tmp dir:       $TMP"
note "data dir:      $DATA"
note "socket:        $SOCK"
note "caddy port:    $CADDY_PORT"
note "caddy admin:   127.0.0.1:$CADDY_ADMIN_PORT"
note "identity:      $USERNAME@$DOMAIN  base=$BASE_URL"

# ===========================================================================
#  Cleanup: kill daemon AND Caddy, dump logs on failure, rm temp dir.
# ===========================================================================
DAEMON_PID=""
CADDY_PID=""

dump_logs() {
    yellow "----- daemon.log -----"
    [ -f "$DAEMON_LOG" ] && cat "$DAEMON_LOG" >&2 || true
    yellow "----- caddy.run.log -----"
    [ -f "$CADDY_RUN_LOG" ] && cat "$CADDY_RUN_LOG" >&2 || true
    if [ -f "$CADDY_ACCESS_LOG" ] && [ -s "$CADDY_ACCESS_LOG" ]; then
        yellow "----- caddy.log (access) -----"
        cat "$CADDY_ACCESS_LOG" >&2 || true
    fi
}

cleanup() {
    local rc=$?
    # On any non-zero exit, dump the logs so CI output is self-contained.
    if [ "$rc" != "0" ]; then
        red "run-caddy.sh failed (exit $rc) — dumping logs"
        dump_logs
    fi
    if [ -n "$CADDY_PID" ] && kill -0 "$CADDY_PID" 2>/dev/null; then
        kill "$CADDY_PID" 2>/dev/null || true
        wait "$CADDY_PID" 2>/dev/null || true
    fi
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_TMP:-0}" != "1" ]; then
        rm -rf "$TMP"
    else
        yellow "KEEP_TMP=1 → leaving $TMP for inspection"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$DATA"

# ===========================================================================
#  STEP 1 — Build / locate the binary; assert it is executable. (bug #1)
#  Mirrors run.sh exactly.
# ===========================================================================
note "STEP 1 — locate binary"
if [ -n "${ANNEXWYRM_BINARY:-}" ]; then
    BINARY="$ANNEXWYRM_BINARY"
else
    note "building annexwyrm via nix build .#default"
    ( cd "$REPO" && nix build .#default --out-link "$REPO/result" )
    BINARY="$REPO/result/bin/annexwyrm"
fi
if [ ! -x "$BINARY" ]; then
    red "binary not found / not executable (bug #1): $BINARY"
    exit 1
fi
green "  ✓ binary is executable: $BINARY"

# Static dir derivation MUST mirror the home-manager module:
#   …/bin/annexwyrm → …/share/annexwyrm/static
STATIC_DIR="$(dirname "$(dirname "$BINARY")")/share/annexwyrm/static"
if [ ! -f "$STATIC_DIR/style.css" ]; then
    red "package did not install CSS at $STATIC_DIR/style.css"
    red "(this would have surfaced as a /static 404 — fail early instead)"
    exit 1
fi
green "  ✓ package static dir has style.css: $STATIC_DIR/style.css"

# ===========================================================================
#  STEP 2 — Generate an isolated Caddyfile and `caddy validate` it. (bug #3)
#
#  The site block mirrors nix/home-manager-module.nix, parameterised for the
#  test. CRITICAL: the request_body block is written MULTI-LINE. The
#  one-line form `request_body { max_size 4GB }` is a Caddy parse error and
#  is exactly the regression Step 2's `caddy validate` guards against.
# ===========================================================================
note "STEP 2 — generate + validate Caddyfile"

# admin off would disable validate-against-running; instead we point admin at
# a probed-free port so this Caddy never touches the user's :2019 admin API.
cat > "$CADDYFILE" <<EOF
{
    admin 127.0.0.1:${CADDY_ADMIN_PORT}
}

# Explicit http:// so Caddy does NOT attempt ACME/TLS — this is the http://
# dev path where bug #6 (Secure cookie dropped) lived.
http://${DOMAIN}:${CADDY_PORT} {
    encode zstd gzip

    # Multi-line block form is mandatory. The one-line
    # \`request_body { max_size 4GB }\` is a Caddyfile parse error
    # ("Unexpected next token after '{' on same line"). This is bug #3.
    request_body {
        max_size 4GB
    }

    reverse_proxy unix/${SOCK} {
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            versions 1.1
            read_buffer 64KB
            write_buffer 64KB
        }
    }

    # Static assets are served by Caddy from the PACKAGE store path, never
    # the (empty) data dir — that empty-dir mistake was bug #2.
    handle_path /static/* {
        root * ${STATIC_DIR}
        file_server
    }

    log {
        output file ${CADDY_ACCESS_LOG}
        format json
    }
}
EOF

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile > "$TMP/validate.log" 2>&1; then
    red "caddy validate FAILED (bug #3 territory) — Caddyfile + stderr follow:"
    yellow "----- Caddyfile -----"
    cat "$CADDYFILE" >&2
    yellow "----- caddy validate output -----"
    cat "$TMP/validate.log" >&2
    exit 1
fi
green "  ✓ Caddyfile validates (multi-line request_body block)"

# ===========================================================================
#  STEP 3 — init the data dir with the served identity. (bug #4)
# ===========================================================================
note "STEP 3 — init data dir with served identity"
ANNEXWYRM_DOMAIN="$DOMAIN" \
ANNEXWYRM_BASE_URL="$BASE_URL" \
ANNEXWYRM_USERNAME="$USERNAME" \
ANNEXWYRM_INSTANCE_NAME="$INSTANCE_NAME" \
ANNEXWYRM_PASSWORD="$TEST_PASS" \
ANNEXWYRM_DATA="$DATA" \
    "$BINARY" init "$DATA"

DB="$DATA/annexwyrm.db"
[ -f "$DB" ] || { red "init did not create $DB"; exit 1; }

# A small SQL-assertion helper with explicit expected/observed messages.
assert_sql() {
    local sql="$1" expected="$2" label="${3:-sql}"
    local got
    got=$(sqlite3 "$DB" "$sql" || true)
    if [ "$got" != "$expected" ]; then
        red "SQL assertion failed: $label"
        red "  query:    $sql"
        red "  expected: $expected"
        red "  observed: $got"
        return 1
    fi
    green "  ✓ $label = $got"
}

assert_sql "SELECT count(*) FROM actor WHERE local=1;" "1" \
    "exactly one local actor"
assert_sql "SELECT username FROM actor WHERE local=1;" "sweater" \
    "actor username (catches bug #4 default 'alice')"
assert_sql "SELECT domain FROM actor WHERE local=1;" "annexwyrm.localhost" \
    "actor domain (catches bug #4 default 'annexwyrm.local')"
assert_sql "SELECT id FROM actor WHERE local=1;" \
    "http://annexwyrm.localhost/users/sweater" \
    "actor id (catches bug #4 https default)"
assert_sql "SELECT count(*) FROM local_login;" "1" \
    "exactly one local_login row"
# The FK MUST actually join — bug #4's symptom was a local_login row whose
# actor_id pointed at a non-existent actor. A bare count is insufficient.
assert_sql \
    "SELECT count(*) FROM local_login l JOIN actor a ON a.id = l.actor_id WHERE a.local=1;" \
    "1" "local_login FK joins to the local actor (bug #4 core)"

# Idempotency: a second init must not change the counts.
note "  re-running init (idempotency)"
ANNEXWYRM_DOMAIN="$DOMAIN" \
ANNEXWYRM_BASE_URL="$BASE_URL" \
ANNEXWYRM_USERNAME="$USERNAME" \
ANNEXWYRM_INSTANCE_NAME="$INSTANCE_NAME" \
ANNEXWYRM_PASSWORD="$TEST_PASS" \
ANNEXWYRM_DATA="$DATA" \
    "$BINARY" init "$DATA"
assert_sql "SELECT count(*) FROM actor WHERE local=1;" "1" \
    "actor count unchanged after re-init"
assert_sql "SELECT count(*) FROM local_login;" "1" \
    "local_login count unchanged after re-init"

# ===========================================================================
#  STEP 4 — start the daemon, then Caddy; confirm both live.
# ===========================================================================
note "STEP 4 — start daemon + Caddy"
# Serve with the SAME identity env (minus ANNEXWYRM_PASSWORD).
ANNEXWYRM_DOMAIN="$DOMAIN" \
ANNEXWYRM_BASE_URL="$BASE_URL" \
ANNEXWYRM_USERNAME="$USERNAME" \
ANNEXWYRM_INSTANCE_NAME="$INSTANCE_NAME" \
ANNEXWYRM_SOCKET="$SOCK" \
ANNEXWYRM_DATA="$DATA" \
ANNEXWYRM_ARCHIVE_REMOTE="$ARCHIVE_REMOTE" \
ANNEXWYRM_PUBLIC_REMOTE="$PUBLIC_REMOTE" \
ANNEXWYRM_PUBLIC_URL_BASE="$PUBLIC_URL_BASE" \
ANNEXWYRM_SERVE_DRAIN=0 \
    "$BINARY" serve > "$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

wait_for_socket "$SOCK" 10 || {
    red "daemon failed to bring up its socket"
    exit 1
}
# Smoke check the socket actually speaks HTTP (same retry loop as run.sh).
ready=0
for _ in $(seq 1 10); do
    if curl --silent --output /dev/null --max-time 2 \
            --unix-socket "$SOCK" "http://x/" >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 0.5
done
[ "$ready" = "1" ] || { red "daemon socket not accepting HTTP after 5s"; exit 1; }
green "  ✓ daemon up + speaking HTTP on socket (pid $DAEMON_PID)"

# Start the ISOLATED Caddy. Its admin endpoint is on a probed-free port (set
# in the global options of the Caddyfile), so it never touches the user's
# Caddy on :2019 or their ~/Caddy config.
caddy run --config "$CADDYFILE" --adapter caddyfile \
    > "$CADDY_RUN_LOG" 2>&1 &
CADDY_PID=$!

# Wait for Caddy with a bounded poll loop — NOT a foreground sleep.
caddy_ready=0
for _ in $(seq 1 20); do
    if ! kill -0 "$CADDY_PID" 2>/dev/null; then
        red "Caddy process exited during startup"
        exit 1
    fi
    code=$(caddy_curl --output /dev/null --max-time 2 \
            --write-out '%{http_code}' "${CADDY_BASE}/" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        caddy_ready=1; break
    fi
    sleep 0.5
done
if [ "$caddy_ready" != "1" ]; then
    red "Caddy did not start accepting requests within ~10s"
    exit 1
fi
# Assert both processes are still alive (a dead daemon = bug #1 EACCES).
kill -0 "$DAEMON_PID" 2>/dev/null || { red "daemon died after launch (bug #1?)"; exit 1; }
kill -0 "$CADDY_PID"  2>/dev/null || { red "Caddy died after launch"; exit 1; }
# Daemon log must not contain crash markers.
if grep -Eqi 'panic|internal error|EACCES' "$DAEMON_LOG"; then
    red "daemon log contains a crash marker"
    cat "$DAEMON_LOG" >&2
    exit 1
fi
green "  ✓ daemon (pid $DAEMON_PID) + Caddy (pid $CADDY_PID) both live"

# ===========================================================================
#  STEP 5 — homepage loads, is styled, and goes through Caddy. (bugs #2, #6 transport)
# ===========================================================================
note "STEP 5 — homepage / CSS / Via"

# 5a — homepage HTML.
HOME_HEADERS="$(dump_headers_tcp "/")"
assert_status_tcp "/" 200 "homepage status"
ct="$(header_value "$HOME_HEADERS" "content-type")"
[ "$ct" = "text/html; charset=utf-8" ] || {
    red "homepage Content-Type expected 'text/html; charset=utf-8', got '$ct'"
    exit 1
}
green "  ✓ homepage Content-Type: $ct"

HOME_HTML="$(fetch_html_anon_tcp "/")"
assert_grep "$HOME_HTML" '<link rel="stylesheet" href="/static/style.css">' \
    "stylesheet reference"
assert_grep "$HOME_HTML" 'sweater&#39;s annexwyrm (caddy e2e)' \
    "instance name (HTML-escaped apostrophe → &#39;)"
assert_grep "$HOME_HTML" '<a href="/">annexwyrm</a>' \
    "brand chrome"
assert_grep "$HOME_HTML" 'nothing public yet.' \
    "empty-state marker (clean baseline)"
# (c) DB genuinely empty before uploads.
assert_sql "SELECT count(*) FROM item;" "0" "no items before uploads"

# 5b — CSS is served, by Caddy, as CSS. THE bug-#2 assertion.
assert_status_tcp "/static/style.css" 200 "CSS status (bug #2)"
CSS_HEADERS="$(dump_headers_tcp "/static/style.css")"
css_ct="$(header_value "$CSS_HEADERS" "content-type")"
if ! printf '%s' "$css_ct" | grep -qi 'text/css'; then
    red "CSS Content-Type expected to contain text/css, got '$css_ct'"
    exit 1
fi
green "  ✓ CSS Content-Type contains text/css: $css_ct"
CSS_BODY="$(fetch_html_anon_tcp "/static/style.css")"
# Assert a real CSS marker so a wrong-but-200 page (e.g. an HTML 404 body
# returned with status 200) still fails.
assert_grep "$CSS_BODY" '\-\-bg:        #f3eed9;' "CSS content marker (--bg)"
assert_grep "$CSS_BODY" '\.rating' "CSS content marker (.rating)"
# The daemon has no /static route — Caddy serves it directly. Prove the asset
# never reached the Koka process.
if grep -q '/static/style.css' "$DAEMON_LOG"; then
    red "daemon log mentions /static/style.css — Caddy is not fronting static"
    exit 1
fi
green "  ✓ /static/style.css never hit the daemon (Caddy serves it)"

# 5c — the request flowed through Caddy (the Via proof). Every TCP helper
# (caddy_curl / header_value / upload_tcp, the §4.1 macOS-correct, BSD-awk-
# proof twins of run.sh's socket helpers) lives in lib.sh and inherits this
# proxied-path guarantee.
assert_via_caddy "$HOME_HEADERS" "homepage"

# ===========================================================================
#  STEP 6 — login via the form; cookie MUST NOT be Secure. (bug #6)
# ===========================================================================
note "STEP 6 — form login + cookie attributes"
LOGIN_HEADERS_FILE="$TMP/login.headers"
: > "$JAR"
# No -L: inspect the 303 + Set-Cookie directly. x-www-form-urlencoded body.
caddy_curl \
    --output /dev/null \
    --dump-header "$LOGIN_HEADERS_FILE" \
    --cookie-jar "$JAR" \
    --data-urlencode "username=$USERNAME" \
    --data-urlencode "password=$TEST_PASS" \
    "${CADDY_BASE}/login"
LOGIN_HEADERS="$(cat "$LOGIN_HEADERS_FILE")"

login_status="$(head -1 "$LOGIN_HEADERS_FILE" | awk '{print $2}' | tr -d '\r')"
[ "$login_status" = "303" ] || {
    red "login expected 303 (success), got $login_status (200 = auth failed)"
    cat "$LOGIN_HEADERS_FILE" >&2
    exit 1
}
green "  ✓ login status 303"
login_loc="$(header_value "$LOGIN_HEADERS" "location")"
[ "$login_loc" = "/" ] || { red "login Location expected '/', got '$login_loc'"; exit 1; }
green "  ✓ login Location: /"
assert_via_caddy "$LOGIN_HEADERS" "login"

# The Set-Cookie line (case-insensitive grab, CR-stripped).
SET_COOKIE="$(printf '%s\n' "$LOGIN_HEADERS" | grep -i '^set-cookie:' | head -1 | tr -d '\r')"
[ -n "$SET_COOKIE" ] || { red "login set no Set-Cookie header"; exit 1; }
# Must start with session=<non-empty>.
if ! printf '%s' "$SET_COOKIE" | grep -Eq 'session=[^;[:space:]]+'; then
    red "Set-Cookie does not set a non-empty session token: $SET_COOKIE"
    exit 1
fi
green "  ✓ Set-Cookie sets a session token"
assert_grep "$SET_COOKIE" 'HttpOnly' "cookie HttpOnly"
assert_grep "$SET_COOKIE" 'Path=/' "cookie Path=/"
assert_grep "$SET_COOKIE" 'SameSite=Lax' "cookie SameSite=Lax"
assert_grep "$SET_COOKIE" 'Max-Age=1209600' "cookie Max-Age=1209600"
# THE bug-#6 assertion: NO Secure attribute over http://.
if printf '%s' "$SET_COOKIE" | grep -qi 'secure'; then
    red "Set-Cookie carries 'Secure' over http:// (bug #6): $SET_COOKIE"
    exit 1
fi
green "  ✓ Set-Cookie has NO Secure attribute (bug #6 guard)"

# Extract the token and prove it landed in the session table for the right actor.
TOK="$(printf '%s' "$SET_COOKIE" | sed -E 's/.*session=([^;[:space:]]+).*/\1/')"
[ -n "$TOK" ] || { red "could not extract session token from cookie"; exit 1; }
assert_sql "SELECT count(*) FROM session;" "1" "one session row after login"
assert_sql "SELECT count(*) FROM session WHERE token = '$TOK';" "1" \
    "session row matches the cookie token"
assert_sql \
    "SELECT count(*) FROM session s JOIN actor a ON a.id = s.actor_id WHERE a.username='sweater';" \
    "1" "session belongs to actor 'sweater' (identity coherence)"

# ===========================================================================
#  STEP 7 — wrong password rejected, sets no session.
# ===========================================================================
note "STEP 7 — wrong password rejected"
BAD_HEADERS_FILE="$TMP/badlogin.headers"
BAD_BODY="$TMP/badlogin.body"
caddy_curl \
    --output "$BAD_BODY" \
    --dump-header "$BAD_HEADERS_FILE" \
    --cookie-jar "$TMP/throwaway.jar" \
    --data-urlencode "username=$USERNAME" \
    --data-urlencode "password=WRONG" \
    "${CADDY_BASE}/login"
bad_status="$(head -1 "$BAD_HEADERS_FILE" | awk '{print $2}' | tr -d '\r')"
[ "$bad_status" = "200" ] || {
    red "wrong-password login expected 200 (re-render), got $bad_status"
    exit 1
}
green "  ✓ wrong password → 200 (form re-rendered, no redirect)"
assert_grep "$(cat "$BAD_BODY")" 'invalid credentials' "invalid-credentials error"
assert_grep "$(cat "$BAD_BODY")" 'class="err"' "error CSS class"
# No Set-Cookie that sets a non-empty session.
if printf '%s\n' "$(cat "$BAD_HEADERS_FILE")" \
        | grep -i '^set-cookie:' | grep -Eq 'session=[^;[:space:]]+'; then
    red "wrong-password login set a session cookie — must not"
    exit 1
fi
green "  ✓ wrong password set no session cookie"
assert_sql "SELECT count(*) FROM session;" "1" "session count unchanged after bad login"

# ===========================================================================
#  STEP 7b — the upload form (owner session) has NO privacy selector and a
#  publish_file checkbox (default OFF). The single-tenant file-publication
#  model retired per-item privacy entirely (§5.1, touchpoint 20): the only
#  choice on the form is whether to ALSO publish the file blob. We fetch the
#  form through Caddy with the live session jar (anon GET /upload would 403),
#  so this also re-proves the proxied path (Via).
# ===========================================================================
note "STEP 7b — upload form: no privacy selector, publish_file checkbox present"
UPLOAD_FORM_HEADERS="$(dump_headers_tcp "/upload" "$JAR")"
assert_via_caddy "$UPLOAD_FORM_HEADERS" "upload form"
UPLOAD_FORM_HTML="$(fetch_html_tcp "/upload" "$JAR")"
# The form renders for the owner (a header/upload chrome marker present).
assert_grep "$UPLOAD_FORM_HTML" '<form action="/upload" method="post" enctype="multipart/form-data">' \
    "upload form element"
# THE assertion: no per-item privacy <select> anywhere on the form. (The
# rating <select> is fine; it is `name="rating"`, never `name="privacy"`.)
if printf '%s' "$UPLOAD_FORM_HTML" | grep -Eq 'name="privacy"|<select[^>]*privacy'; then
    red "upload form still renders a privacy selector — must be gone (§5.1)"
    printf '%s\n' "$UPLOAD_FORM_HTML" | grep -nE 'privacy' >&2 || true
    exit 1
fi
green "  ✓ upload form has NO privacy selector"
# And the publish_file checkbox IS present, default OFF (no `checked`).
assert_grep "$UPLOAD_FORM_HTML" '<input type="checkbox" name="publish_file" value="1">' \
    "publish_file checkbox present"
if printf '%s' "$UPLOAD_FORM_HTML" \
        | grep -E 'name="publish_file"' | grep -qi 'checked'; then
    red "publish_file checkbox is pre-checked — must default OFF (§5.1)"; exit 1; fi
green "  ✓ publish_file checkbox defaults OFF (not pre-checked)"
# No legacy manual-mirror fieldset either (touchpoint 2).
if printf '%s' "$UPLOAD_FORM_HTML" | grep -Eq 'name="remote_(target|kind|label)"'; then
    red "upload form still renders the retired manual-mirror fields"; exit 1; fi
green "  ✓ upload form has no manual-mirror (remote_*) fields"

# ===========================================================================
#  Generate the two PDFs.
# ===========================================================================
note "generating PDFs"
PDF_PUBLIC="$TMP/public.pdf"
PDF_PRIVATE="$TMP/private.pdf"
python3 "$THIS_DIR/make-pdf.py" "Public PDF: a serene treatise" > "$PDF_PUBLIC"
python3 "$THIS_DIR/make-pdf.py" "Private PDF: the inner sanctum" > "$PDF_PRIVATE"
[ -s "$PDF_PUBLIC" ]  || { red "empty public PDF";  exit 1; }
[ -s "$PDF_PRIVATE" ] || { red "empty private PDF"; exit 1; }

# Helper: assert an upload Location is a /items/<hex> path and that a
# corresponding `upload/done id=<BASE_URL><path>` line exists in the log.
assert_items_path() {
    local path="$1" label="$2"
    if ! printf '%s' "$path" | grep -Eq '^/items/[0-9a-f]+$'; then
        red "$label Location not /items/<hex>: $path"
        exit 1
    fi
    green "  ✓ $label Location: $path"
}

# ===========================================================================
#  STEP 8 — upload the public PDF (multipart through Caddy).
# ===========================================================================
note "STEP 8 — upload public PDF (archived; the file is gated, the review is not)"
upload_tcp "$JAR" "$PDF_PUBLIC" \
    "Public PDF" "" "<p>A document we want everyone to see.</p>" \
    "99" ""
PUBLIC_PATH="$UPLOAD_LOCATION"
PUB_UP_HEADERS="$UPLOAD_HEADERS"
PUBLIC_SLUG="${PUBLIC_PATH##*/}"
assert_items_path "$PUBLIC_PATH" "public upload"
# IDENTITY url uses BASE_URL (no port), NOT the transport host:port. (§3.4)
PUBLIC_URL="${BASE_URL}${PUBLIC_PATH}"
assert_via_caddy "$PUB_UP_HEADERS" "public upload"
# (b) log line: body streamed through Caddy intact and was ingested. The
#     shape now carries file_published=0 (archived), not remotes=N.
grep -Eq "upload/done id=${PUBLIC_URL} size=[0-9]+ file_published=0" "$DAEMON_LOG" || {
    red "missing 'upload/done id=${PUBLIC_URL} … file_published=0' in daemon log"
    grep 'upload/done' "$DAEMON_LOG" >&2 || true
    exit 1
}
green "  ✓ daemon logged upload/done id=$PUBLIC_URL file_published=0"
# (c) DB state — every item is public; the gate is the file blob.
assert_sql "SELECT count(*) FROM item;" "1" "one item so far"
assert_sql "SELECT file_published FROM item WHERE name='Public PDF';" "0" \
    "public PDF is archived (file_published=0)"
assert_sql "SELECT id FROM item WHERE name='Public PDF';" "$PUBLIC_URL" \
    "public item id == \$PUBLIC_URL"
assert_sql "SELECT media_type FROM item WHERE name='Public PDF';" "application/pdf" \
    "public item media_type"
assert_sql "SELECT byte_size > 0 FROM item WHERE name='Public PDF';" "1" \
    "public item byte_size > 0"
# (c) bytes landed in the archive backend only.
[ -f "$ARCHIVE_REMOTE/$PUBLIC_SLUG" ] || { red "public PDF archive blob missing"; exit 1; }
green "  ✓ public PDF archive blob present"

# ===========================================================================
#  STEP 9 — upload the private PDF.
# ===========================================================================
# Formerly the "private" PDF. There is no per-item privacy now: this is just
# a second archived item whose review is public but whose file is not yet
# published. (The name is kept for downstream assertions.)
note "STEP 9 — upload second PDF (archived)"
upload_tcp "$JAR" "$PDF_PRIVATE" \
    "Private PDF" "" "<p>This stays archived for now.</p>" \
    "99" ""
PRIVATE_PATH="$UPLOAD_LOCATION"
PRIV_UP_HEADERS="$UPLOAD_HEADERS"
PRIVATE_SLUG="${PRIVATE_PATH##*/}"
assert_items_path "$PRIVATE_PATH" "second upload"
PRIVATE_URL="${BASE_URL}${PRIVATE_PATH}"
assert_via_caddy "$PRIV_UP_HEADERS" "second upload"
grep -Eq "upload/done id=${PRIVATE_URL} size=[0-9]+ file_published=0" "$DAEMON_LOG" || {
    red "missing 'upload/done id=${PRIVATE_URL} … file_published=0' in daemon log"; exit 1; }
green "  ✓ daemon logged upload/done id=$PRIVATE_URL file_published=0"
assert_sql "SELECT file_published FROM item WHERE name='Private PDF';" "0" \
    "second item is archived (file_published=0)"
assert_sql "SELECT count(*) FROM item;" "2" "two items total"

# ===========================================================================
#  STEP 9b — archived item page, OWNER pre-publish (§5.2). The owner viewing
#  an archived item sees the full review, the "file archived, not published"
#  line, NO download link, and the publish-file action form (their affordance
#  to publish later). This is the owner half of "the archived page hides the
#  download"; N3/Step 15 assert the anon half. We fetch with the live jar.
# ===========================================================================
note "STEP 9b — archived item page (owner, pre-publish): no download, publish-file form"
ARCH_OWNER_HEADERS="$(dump_headers_tcp "$PRIVATE_PATH" "$JAR")"
assert_status_tcp "$PRIVATE_PATH" 200 "archived item page status (owner)"
assert_via_caddy "$ARCH_OWNER_HEADERS" "archived item page (owner)"
ARCH_OWNER_HTML="$(fetch_html_tcp "$PRIVATE_PATH" "$JAR")"
assert_grep "$ARCH_OWNER_HTML" 'Private PDF' "owner sees the archived item's review"
assert_grep "$ARCH_OWNER_HTML" 'file archived, not published' \
    "owner sees the archived file-state line (pre-publish)"
# The owner gets the publish-file affordance — the form pointing at this item.
assert_grep "$ARCH_OWNER_HTML" "action=\"/items/$PRIVATE_SLUG/publish-file\" method=\"post\"" \
    "owner sees the publish-file action form"
# But NO download link while archived — the file is not yet published.
if printf '%s' "$ARCH_OWNER_HTML" | grep -q 'class="download"'; then
    red "archived item page leaked a download anchor to the OWNER pre-publish"; exit 1; fi
green "  ✓ owner pre-publish: no download anchor on the archived page"

# ===========================================================================
#  STEP 10 — review of the public PDF, rating +2, non-empty in_reply_to.
# ===========================================================================
note "STEP 10 — review of public PDF (+2)"
upload_tcp "$JAR" "$PDF_PUBLIC" \
    "Review: praise public PDF" "" \
    "<p>Praise public PDF. A perfectly reasonable read.</p>" \
    "2" "$PUBLIC_URL"
REVIEW_A_PATH="$UPLOAD_LOCATION"
REV_A_UP_HEADERS="$UPLOAD_HEADERS"
assert_items_path "$REVIEW_A_PATH" "review A upload"
assert_via_caddy "$REV_A_UP_HEADERS" "review A upload"
grep -q "upload/done id=${BASE_URL}${REVIEW_A_PATH}" "$DAEMON_LOG" || {
    red "missing upload/done for review A"; exit 1; }
green "  ✓ review A upload/done logged"
assert_sql "SELECT rating FROM item WHERE name LIKE 'Review: praise public%';" "2" \
    "review A rating +2"
assert_sql "SELECT in_reply_to FROM item WHERE name LIKE 'Review: praise public%';" \
    "$PUBLIC_URL" "review A in_reply_to == \$PUBLIC_URL"

# ===========================================================================
#  STEP 11 — review of the private PDF, rating +3, with a hyperlink in body.
# ===========================================================================
note "STEP 11 — review of private PDF (+3) with hyperlink"
REVIEW_B_CONTENT="<p>Praise private PDF <em>even more</em> — it builds upon the ideas from <a href=\"$PRIVATE_URL\">privatePDF</a>.</p>"
upload_tcp "$JAR" "$PDF_PRIVATE" \
    "Review: praise private PDF even more" "" "$REVIEW_B_CONTENT" \
    "3" "$PRIVATE_URL"
REVIEW_B_PATH="$UPLOAD_LOCATION"
REV_B_UP_HEADERS="$UPLOAD_HEADERS"
assert_items_path "$REVIEW_B_PATH" "review B upload"
assert_via_caddy "$REV_B_UP_HEADERS" "review B upload"
grep -q "upload/done id=${BASE_URL}${REVIEW_B_PATH}" "$DAEMON_LOG" || {
    red "missing upload/done for review B"; exit 1; }
green "  ✓ review B upload/done logged"
assert_sql "SELECT rating FROM item WHERE name LIKE 'Review: praise private%';" "3" \
    "review B rating +3"
assert_sql "SELECT in_reply_to FROM item WHERE name LIKE 'Review: praise private%';" \
    "$PRIVATE_URL" "review B in_reply_to == \$PRIVATE_URL"
assert_sql "SELECT count(*) FROM item;" "4" "four items total"

# ===========================================================================
#  STEP 12 — the review item pages render correctly (anon; reviews public).
# ===========================================================================
note "STEP 12 — review pages render preamble + badge + stars + hyperlink"

REVIEW_B_HEADERS="$(dump_headers_tcp "$REVIEW_B_PATH")"
assert_status_tcp "$REVIEW_B_PATH" 200 "review B page status"
rb_ct="$(header_value "$REVIEW_B_HEADERS" "content-type")"
[ "$rb_ct" = "text/html; charset=utf-8" ] || {
    red "review B Content-Type expected text/html; charset=utf-8, got '$rb_ct'"; exit 1; }
green "  ✓ review B Content-Type: $rb_ct"
assert_via_caddy "$REVIEW_B_HEADERS" "review B page"

REVIEW_B_HTML="$(fetch_html_anon_tcp "$REVIEW_B_PATH")"
# review-of preamble with hyperlinked URL == the in-reply-to target.
assert_grep "$REVIEW_B_HTML" 'class="review-of"' "review-of preamble class"
assert_grep "$REVIEW_B_HTML" 'review of' "review-of preamble text"
assert_grep "$REVIEW_B_HTML" "<p class=\"review-of\">review of <a href=\"$PRIVATE_URL\">" \
    "review-of preamble links to \$PRIVATE_URL"
# Rating badge.
assert_grep "$REVIEW_B_HTML" '<span class="rating positive">' "rating positive class (+3)"
assert_grep "$REVIEW_B_HTML" '\[+3\]' "rating badge [+3]"
# Stars: exactly three filled.
assert_grep "$REVIEW_B_HTML" '★★★' "three filled stars"
# Body hyperlink survives verbatim through multipart (--form-string gotcha).
assert_grep "$REVIEW_B_HTML" '>privatePDF</a>' "body hyperlink anchor text"
assert_grep "$REVIEW_B_HTML" "href=\"$PRIVATE_URL\"" "body hyperlink href == \$PRIVATE_URL"

REVIEW_A_HEADERS="$(dump_headers_tcp "$REVIEW_A_PATH")"
assert_status_tcp "$REVIEW_A_PATH" 200 "review A page status"
assert_via_caddy "$REVIEW_A_HEADERS" "review A page"
REVIEW_A_HTML="$(fetch_html_anon_tcp "$REVIEW_A_PATH")"
assert_grep "$REVIEW_A_HTML" '<span class="rating positive">' "review A rating positive class (+2)"
assert_grep "$REVIEW_A_HTML" '\[+2\]' "review A badge [+2]"
# Exactly two stars: assert ★★ present and ★★★ absent.
assert_grep "$REVIEW_A_HTML" '★★' "review A two filled stars"
if printf '%s' "$REVIEW_A_HTML" | grep -q '★★★'; then
    red "review A shows three stars but rating is +2"; exit 1; fi
green "  ✓ review A shows exactly two stars"
assert_grep "$REVIEW_A_HTML" "href=\"$PUBLIC_URL\"" "review A preamble links to \$PUBLIC_URL"

# ===========================================================================
#  STEP 13 — homepage now lists the reviews with badges + [review].
# ===========================================================================
note "STEP 13 — homepage lists reviews"
assert_status_tcp "/" 200 "homepage status (post-upload)"
HOME2_HTML="$(fetch_html_anon_tcp "/")"
assert_grep "$HOME2_HTML" 'Review: praise public PDF' "home: review A title"
assert_grep "$HOME2_HTML" 'Review: praise private PDF even more' "home: review B title"
assert_grep "$HOME2_HTML" '\[+2\]' "home: badge +2"
assert_grep "$HOME2_HTML" '\[+3\]' "home: badge +3"
assert_grep "$HOME2_HTML" 'class="rating positive"' "home: positive-rating CSS hook"
assert_grep "$HOME2_HTML" '\[review\]' "home: [review] marker"
if printf '%s' "$HOME2_HTML" | grep -q 'nothing public yet.'; then
    red "home still shows empty-state but archive is non-empty"; exit 1; fi
green "  ✓ home no longer shows empty-state"
# No privacy word ever appears on the home list.
if printf '%s' "$HOME2_HTML" | grep -qiE 'class="meta">[^<]*· (public|private|unlisted|followers)'; then
    red "home list still renders a privacy word"; exit 1; fi
green "  ✓ no privacy word on the home list"
# (c) every item is public; the home list shows them ALL (no WHERE filter).
assert_sql "SELECT count(*) FROM item;" "4" "four items total on home"

# ===========================================================================
#  CADDY STEP N1 — publish-file THROUGH Caddy (owner session, still logged in).
#  Proves the publish-file Update path works proxied, and the bytes reach the
#  public backend.
# ===========================================================================
note "STEP N1 — publish-file through Caddy"
N1_HDR="$TMP/n1.headers"
n1_status=$(caddy_curl --cookie "$JAR" --request POST --data '' \
    --output /dev/null --dump-header "$N1_HDR" --write-out '%{http_code}' \
    "${CADDY_BASE}${PUBLIC_PATH}/publish-file")
[ "$n1_status" = "303" ] || { red "publish-file via Caddy: expected 303, got $n1_status"; exit 1; }
green "  ✓ publish-file via Caddy → 303"
N1_HEADERS="$(cat "$N1_HDR")"
n1_loc="$(header_value "$N1_HEADERS" "location")"
[ "$n1_loc" = "$PUBLIC_PATH" ] || { red "publish-file Location expected $PUBLIC_PATH, got $n1_loc"; exit 1; }
green "  ✓ publish-file via Caddy Location = $PUBLIC_PATH"
assert_via_caddy "$N1_HEADERS" "publish-file"
# (b) Update emission.
assert_log_grep "$DAEMON_LOG" \
    '^\[info\] outbox/publish id='"${BASE_URL}"'/activities/[0-9a-f]+ type=Update recipients=0' \
    "N1: publish-file emits Update"
# (c) DB + bytes.
assert_sql "SELECT file_published FROM item WHERE name='Public PDF';" "1" \
    "N1: public PDF now file_published=1"
assert_sql "SELECT file_public_url FROM item WHERE name='Public PDF';" \
    "http://example.test/dl/$PUBLIC_SLUG" "N1: minted hermetic download URL stored"
[ -f "$PUBLIC_REMOTE/$PUBLIC_SLUG" ] || { red "N1: public blob missing on disk"; exit 1; }
green "  ✓ N1: public blob present in the public backend"

# ===========================================================================
#  CADDY STEP N2 — published item page through Caddy renders the download link.
# ===========================================================================
note "STEP N2 — published item page through Caddy"
N2_HEADERS="$(dump_headers_tcp "$PUBLIC_PATH")"
assert_status_tcp "$PUBLIC_PATH" 200 "published item page status"
n2_ct="$(header_value "$N2_HEADERS" "content-type")"
[ "$n2_ct" = "text/html; charset=utf-8" ] || {
    red "published page Content-Type expected text/html; charset=utf-8, got '$n2_ct'"; exit 1; }
green "  ✓ N2: published page Content-Type: $n2_ct"
assert_via_caddy "$N2_HEADERS" "published item page"
N2_HTML="$(fetch_html_anon_tcp "$PUBLIC_PATH")"
assert_grep "$N2_HTML" "class=\"download\" href=\"http://example.test/dl/" "N2: download link rendered"
assert_grep "$N2_HTML" "A document we want everyone to see" "N2: review body still renders"
if printf '%s' "$N2_HTML" | grep -q 'file archived, not published'; then
    red "N2: published page still shows the archived line"; exit 1; fi
green "  ✓ N2: archived line gone on the published page"

# ===========================================================================
#  CADDY STEP N3 — archived item page through Caddy hides the download.
# ===========================================================================
note "STEP N3 — archived item page through Caddy"
N3_HEADERS="$(dump_headers_tcp "$PRIVATE_PATH")"
assert_status_tcp "$PRIVATE_PATH" 200 "archived item page status"
assert_via_caddy "$N3_HEADERS" "archived item page"
N3_HTML="$(fetch_html_anon_tcp "$PRIVATE_PATH")"
assert_grep "$N3_HTML" "file archived, not published" "N3: archived file-state line"
if printf '%s' "$N3_HTML" | grep -q 'class="download"'; then
    red "N3: archived page leaked a download anchor"; exit 1; fi
green "  ✓ N3: no download anchor on the archived page"

# ===========================================================================
#  STEP 14 — logout clears the cookie and deletes the session.
# ===========================================================================
note "STEP 14 — logout clears cookie + deletes session"
LOGOUT_HEADERS_FILE="$TMP/logout.headers"
caddy_curl \
    --output /dev/null \
    --dump-header "$LOGOUT_HEADERS_FILE" \
    --cookie "$JAR" \
    --request POST \
    "${CADDY_BASE}/logout"
LOGOUT_HEADERS="$(cat "$LOGOUT_HEADERS_FILE")"
logout_status="$(head -1 "$LOGOUT_HEADERS_FILE" | awk '{print $2}' | tr -d '\r')"
[ "$logout_status" = "303" ] || { red "logout expected 303, got $logout_status"; exit 1; }
green "  ✓ logout status 303"
logout_loc="$(header_value "$LOGOUT_HEADERS" "location")"
[ "$logout_loc" = "/" ] || { red "logout Location expected '/', got '$logout_loc'"; exit 1; }
green "  ✓ logout Location: /"
assert_via_caddy "$LOGOUT_HEADERS" "logout"
LOGOUT_COOKIE="$(printf '%s\n' "$LOGOUT_HEADERS" | grep -i '^set-cookie:' | head -1 | tr -d '\r')"
[ -n "$LOGOUT_COOKIE" ] || { red "logout set no Set-Cookie header"; exit 1; }
# Empties the cookie: session= with Max-Age=0.
assert_grep "$LOGOUT_COOKIE" 'session=;' "logout cookie session= empty"
assert_grep "$LOGOUT_COOKIE" 'Max-Age=0' "logout cookie Max-Age=0"
assert_grep "$LOGOUT_COOKIE" 'Path=/' "logout cookie Path=/"
assert_grep "$LOGOUT_COOKIE" 'HttpOnly' "logout cookie HttpOnly"
assert_grep "$LOGOUT_COOKIE" 'SameSite=Lax' "logout cookie SameSite=Lax"
if printf '%s' "$LOGOUT_COOKIE" | grep -qi 'secure'; then
    red "logout Set-Cookie carries 'Secure' over http://: $LOGOUT_COOKIE"; exit 1; fi
green "  ✓ logout cookie has NO Secure attribute"
assert_sql "SELECT count(*) FROM session;" "0" "session row deleted on logout"
# Follow-up: the now-stale jar must be refused on an auth-only action.
assert_status_tcp "/upload" 403 "GET /upload with stale jar → 403"
UPLOAD_FORBIDDEN="$(fetch_html_tcp "/upload" "$JAR")"
assert_grep "$UPLOAD_FORBIDDEN" 'login required' "logged-out upload says 'login required'"

# ===========================================================================
#  STEP 15 — anonymous browsing: EVERY item is public (200). There are no
#  private items; the formerly-"private" item is a public review with an
#  archived file, so anon sees the review + the archived file-state, no
#  download link, and no privacy word.
# ===========================================================================
note "STEP 15 — anon: every item is 200 (no 404-for-private)"
assert_status_tcp "$PUBLIC_PATH" 200 "published item reachable anonymously"
assert_status_tcp "$PRIVATE_PATH" 200 "archived item reachable anonymously"
ARCHIVED_ANON_HTML="$(fetch_html_anon_tcp "$PRIVATE_PATH")"
assert_grep "$ARCHIVED_ANON_HTML" 'file archived, not published' \
    "archived item shows the archived file-state to anon"
assert_grep "$ARCHIVED_ANON_HTML" 'Private PDF' \
    "archived item renders its title to anon (it is public)"
if printf '%s' "$ARCHIVED_ANON_HTML" | grep -q 'class="download"'; then
    red "archived item page leaked a download anchor to anon"; exit 1; fi
green "  ✓ archived item: no download anchor to anon"
# The item exists and is archived (file_published=0); no privacy column read.
assert_sql "SELECT file_published FROM item WHERE name='Private PDF';" "0" \
    "archived item persists with file_published=0"

# ===========================================================================
#  Done.
# ===========================================================================
green ""
green "=========================================="
green "  caddy e2e passed."
green "  caddy port: $CADDY_PORT  socket: $SOCK"
green "  data dir:   $DATA"
green "  daemon log: $DAEMON_LOG"
green "=========================================="
