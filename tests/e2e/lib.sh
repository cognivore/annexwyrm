# tests/e2e/lib.sh — shared helpers, sourced by run.sh.
#
# Convention: every helper exits non-zero on failure with a clear message
# on stderr. The harness handles cleanup via traps.

set -euo pipefail

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
note()   { printf '\033[34m::\033[0m %s\n' "$*" >&2; }

# Run curl against the dev socket, suppressing the trailing newline issue
# but always printing what we got back to the run log.
sock_curl() {
    local sock="$1"; shift
    local out
    out=$(curl --silent --show-error --unix-socket "$sock" "$@") || {
        red "curl failed: $*"
        return 1
    }
    printf '%s' "$out"
}

# `assert_status PATH EXPECTED` — checks that GET PATH returns EXPECTED.
assert_status() {
    local sock="$1" path="$2" expected="$3"
    local code
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
                --unix-socket "$sock" \
                "http://x$path" || true)
    if [ "$code" != "$expected" ]; then
        red "expected $expected for $path, got $code"
        return 1
    fi
    green "  ✓ $path → $code"
}

# `assert_grep BODY PATTERN` — fails unless PATTERN matches BODY.
assert_grep() {
    local body="$1" pattern="$2" label="${3:-pattern}"
    if printf '%s' "$body" | grep -q -- "$pattern"; then
        green "  ✓ found $label: $pattern"
    else
        red "missing $label: $pattern"
        printf '%s\n' "$body" | head -40 >&2
        return 1
    fi
}

# assert_sql DB SQL EXPECTED LABEL — run a scalar query, compare exactly.
# Prints the query and both values on failure (failure ergonomics).
assert_sql() {
    local db="$1" sql="$2" expected="$3" label="${4:-sql}"
    local got
    got=$(sqlite3 "$db" "$sql")
    if [ "$got" != "$expected" ]; then
        red "SQL assert failed ($label): expected [$expected], got [$got]"
        red "  query: $sql"
        return 1
    fi
    green "  ✓ $label: $sql → $got"
}

# assert_log_grep LOGFILE PATTERN LABEL — fail unless PATTERN (grep -E) is in
# LOGFILE. The daemon logs to stderr, captured by run.sh into $LOG, so this is
# what we grep for emission lines (NOT stdout — see src/interp/log_console.kk).
assert_log_grep() {
    local log="$1" pattern="$2" label="${3:-log}"
    if grep -Eq -- "$pattern" "$log"; then
        green "  ✓ daemon logged $label: /$pattern/"
    else
        red "daemon log missing $label: /$pattern/"
        yellow "tail of $log:"; tail -40 "$log" >&2 || true
        return 1
    fi
}

# post_action SOCK JAR PATH → echoes "STATUS<TAB>LOCATION" (Location CR-stripped).
# POSTs an empty body carrying the cookie jar; does NOT follow redirects.
# Header parsing is grep -i + sed (BSD-awk-proof; the awk IGNORECASE trick in
# `upload` is a no-op on macOS awk — see the house notes below).
post_action() {
    local sock="$1" jar="$2" path="$3"
    local hdr; hdr=$(mktemp)
    local code
    code=$(curl --silent --show-error \
                --unix-socket "$sock" --cookie "$jar" \
                --request POST --data '' \
                --output /dev/null --dump-header "$hdr" \
                --write-out '%{http_code}' \
                "http://x$path")
    local loc
    loc=$(grep -i '^location:' "$hdr" | head -1 \
          | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
    rm -f "$hdr"
    printf '%s\t%s' "$code" "$loc"
}

# Edit a review's metadata via POST /items/<slug>/edit. The edit form is
# application/x-www-form-urlencoded (no file part), so this uses
# --data-urlencode, NOT multipart. Args:
#   sock jar slug name summary content rating in_reply_to
# Returns "<http_code>\t<location>".
edit_item() {
    local sock="$1" jar="$2" slug="$3"
    local name="$4" summary="$5" content="$6" rating="$7" in_reply_to="$8"
    local tags="${9:-}"
    local hdr; hdr=$(mktemp)
    local code
    code=$(curl --silent --show-error \
                --unix-socket "$sock" --cookie "$jar" \
                --data-urlencode "name=$name" \
                --data-urlencode "summary=$summary" \
                --data-urlencode "content=$content" \
                --data-urlencode "rating=$rating" \
                --data-urlencode "in_reply_to=$in_reply_to" \
                --data-urlencode "tags=$tags" \
                --output /dev/null --dump-header "$hdr" \
                --write-out '%{http_code}' \
                "http://x/items/$slug/edit")
    local loc
    loc=$(grep -i '^location:' "$hdr" | head -1 \
          | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
    rm -f "$hdr"
    printf '%s\t%s' "$code" "$loc"
}

# Attempt an edit with NO session cookie — the owner-gate probe. Returns
# just the HTTP code (we expect 403).
edit_item_anon() {
    local sock="$1" slug="$2"
    curl --silent --output /dev/null --write-out '%{http_code}' \
         --unix-socket "$sock" \
         --data-urlencode "name=HACKED BY ANON" \
         "http://x/items/$slug/edit"
}

# Log in: POST /login with form-encoded credentials, save Set-Cookie
# into a jar file. Subsequent requests use that jar.
login() {
    local sock="$1" jar="$2" user="$3" pass="$4"
    note "logging in as $user"
    curl --silent --output /dev/null --show-error \
         --unix-socket "$sock" \
         --cookie-jar "$jar" \
         --data-urlencode "username=$user" \
         --data-urlencode "password=$pass" \
         "http://x/login"
}

# Upload a file via multipart/form-data. Args:
#   sock jar file_path title summary content rating in_reply_to [publish_file]
#
# There is NO `privacy` field and NO `remote_*` fields in the single-tenant
# file-publication model. The optional 9th arg, when "1", sends
# `publish_file=1` so the upload also publishes the file blob (mints + emits
# the download URL); omitted/empty leaves the file ARCHIVED (default).
#
# Returns the redirect target (item path) via stdout.
upload() {
    local sock="$1" jar="$2" file="$3"
    local title="$4" summary="$5" content="$6"
    local rating="$7" in_reply_to="$8"
    local publish_file="${9:-}"
    local tags="${10:-}"

    # `--form-string` for everything literal — `-F` interprets `<` and `@`
    # as file-read directives, which mangles HTML content and titles.
    local form_args=(
        -F            "file=@$file"
        --form-string "name=$title"
        --form-string "summary=$summary"
        --form-string "content=$content"
        --form-string "rating=$rating"
        --form-string "in_reply_to=$in_reply_to"
    )
    if [ "$publish_file" = "1" ]; then
        form_args+=( --form-string "publish_file=1" )
    fi
    if [ -n "$tags" ]; then
        form_args+=( --form-string "tags=$tags" )
    fi

    # We follow no redirects; the daemon should respond with 303 + Location.
    local tmp_headers tmp_body
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    curl --silent --show-error \
         --unix-socket "$sock" \
         --cookie "$jar" \
         --dump-header "$tmp_headers" \
         --output "$tmp_body" \
         "${form_args[@]}" \
         "http://x/upload" >&2
    # Parse Location with `grep -i` + sed: BSD awk has no working IGNORECASE,
    # so the old `awk 'BEGIN{IGNORECASE=1}'` silently missed the daemon's
    # capitalised `Location:` header (matching post_action's approach).
    local loc
    loc=$(grep -i '^location:' "$tmp_headers" | head -1 \
          | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
    if [ -z "$loc" ]; then
        red "upload: no Location header in response"
        yellow "headers:"
        cat "$tmp_headers" >&2 || true
        yellow "body (first 30 lines):"
        head -30 "$tmp_body" >&2 || true
        rm -f "$tmp_headers" "$tmp_body"
        return 1
    fi
    rm -f "$tmp_headers" "$tmp_body"
    printf '%s' "$loc"
}

# Fetch the rendered HTML at PATH using SESSION (or empty for anon).
fetch_html() {
    local sock="$1" jar="$2" path="$3"
    curl --silent --show-error \
         --unix-socket "$sock" \
         --cookie "$jar" \
         "http://x$path"
}

# Fetch with anon (no cookie jar).
fetch_html_anon() {
    local sock="$1" path="$2"
    curl --silent --show-error \
         --unix-socket "$sock" \
         "http://x$path"
}

# Fetch an item as ActivityPub JSON, anonymously (Accept: ld+json triggers
# prefers-jsonld). Used to prove an archived blob leaks no URL even in the
# machine-readable representation a scraper would request.
fetch_ap_anon() {
    local sock="$1" path="$2"
    curl --silent --show-error \
         --unix-socket "$sock" \
         -H "Accept: application/ld+json" \
         "http://x$path"
}

# Block until SOCK accepts an HTTP request or TIMEOUT seconds elapse.
#
# We probe with `curl --unix-socket` rather than `nc -U -z`: on macOS,
# `nc -U -z` reports failure against this daemon's accept socket even when
# it is fully serving (verified: curl gets 200, nc -z returns 1), so the
# nc probe spuriously fails the wait. The curl probe is the actual contract
# the suites care about — "does it answer HTTP?" — so it is also stricter.
wait_for_socket() {
    local sock="$1" timeout="${2:-5}"
    local elapsed=0
    # timeout is in seconds; poll at 0.2s, so 5× per second.
    local ticks=$((timeout * 5))
    while [ "$elapsed" -lt "$ticks" ]; do
        if [ -S "$sock" ] && \
           curl --silent --output /dev/null --max-time 2 \
                --unix-socket "$sock" "http://x/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
        elapsed=$((elapsed + 1))
    done
    red "socket $sock did not come up within ${timeout}s"
    return 1
}

# ===========================================================================
#  TCP / Caddy-fronted helpers.
#
#  run.sh talks to the daemon over its Unix socket. run-caddy.sh talks to
#  Caddy over TCP (http://127.0.0.1:PORT). These helpers are the TCP twins
#  of the socket helpers above. They differ in three macOS-critical ways:
#
#    1. Every request MUST send `Host: $CADDY_HOST`, because we connect by
#       IP:port but Caddy keys its site block on the hostname.
#    2. Header parsing is case-insensitive via `grep -i`, NOT the
#       `awk 'BEGIN{IGNORECASE=1}'` trick in `upload` above — BSD awk has no
#       IGNORECASE and silently ignores it, so it would miss Caddy's
#       capitalised `Location:` / `Via:` headers.
#    3. We assert the `Via: …Caddy` header to *prove* the request was proxied
#       and did not accidentally hit the socket.
#
#  Callers MUST export CADDY_BASE (e.g. "http://127.0.0.1:54321") and
#  CADDY_HOST (e.g. "annexwyrm.localhost") before using these.
# ===========================================================================

# Base curl wrapper: bakes in the Host header and silent/show-error flags.
# Usage: caddy_curl <curl-args...>   (URLs are passed as $CADDY_BASE<path>)
caddy_curl() {
    curl --silent --show-error -H "Host: ${CADDY_HOST}" "$@"
}

# Lower-case a header dump so downstream greps can use lower-case literals
# regardless of Caddy's capitalisation. (BSD `tr`, no locale surprises.)
_lc() { tr '[:upper:]' '[:lower:]'; }

# `assert_status_tcp PATH EXPECTED [LABEL]` — GET PATH through Caddy, anon.
assert_status_tcp() {
    local path="$1" expected="$2"
    local label="${3:-$path}"
    local code
    code=$(caddy_curl --output /dev/null --write-out '%{http_code}' \
                "${CADDY_BASE}${path}" || true)
    if [ "$code" != "$expected" ]; then
        red "expected $expected for $path, got $code"
        return 1
    fi
    green "  ✓ $path → $code"
}

# `dump_headers_tcp PATH [JAR]` — print the response headers for PATH.
# If JAR is given and non-empty, send it as the cookie jar.
dump_headers_tcp() {
    local path="$1" jar="${2:-}"
    # Fetch with -D - (dump headers to stdout) on a normal GET, discarding the
    # body, rather than HEAD — several routes do not implement HEAD.
    local args=(--silent --show-error --output /dev/null --dump-header -)
    if [ -n "$jar" ]; then
        caddy_curl "${args[@]}" --cookie "$jar" "${CADDY_BASE}${path}"
    else
        caddy_curl "${args[@]}" "${CADDY_BASE}${path}"
    fi
}

# `assert_via_caddy HEADERS LABEL` — fail unless the header dump proves the
# response came through Caddy (`Via: 1.1 Caddy`, case-insensitive).
assert_via_caddy() {
    local headers="$1" label="${2:-via}"
    if printf '%s' "$headers" | _lc | grep -q '^via:.*caddy'; then
        green "  ✓ $label proxied through Caddy (Via header present)"
    else
        red "missing Via: …Caddy header ($label) — response may not be proxied"
        printf '%s\n' "$headers" | head -40 >&2
        return 1
    fi
}

# `header_value HEADERS NAME` — echo the value of header NAME from a header
# dump, case-insensitively, with the trailing CR stripped. Empty if absent.
header_value() {
    local headers="$1" name="$2"
    printf '%s\n' "$headers" \
        | grep -i "^${name}:" \
        | head -1 \
        | sed -E "s/^[^:]*:[[:space:]]*//" \
        | tr -d '\r'
}

# `fetch_html_tcp PATH JAR` — fetch rendered HTML at PATH using cookie JAR.
fetch_html_tcp() {
    local path="$1" jar="${2:-}"
    if [ -n "$jar" ]; then
        caddy_curl --cookie "$jar" "${CADDY_BASE}${path}"
    else
        caddy_curl "${CADDY_BASE}${path}"
    fi
}

# `fetch_html_anon_tcp PATH` — fetch rendered HTML at PATH with no cookies.
fetch_html_anon_tcp() {
    local path="$1"
    caddy_curl "${CADDY_BASE}${path}"
}

# Upload a file via multipart/form-data THROUGH CADDY. Same field discipline
# as the socket `upload` (--form-string for literals, -F only for the file),
# but parses the Location header case-insensitively (BSD-awk-proof).
#
# RETURNS VIA GLOBALS, deliberately: UPLOAD_LOCATION (the redirect path) and
# UPLOAD_HEADERS (the full header dump, for Via / Set-Cookie assertions).
# Call it as a plain statement — NEVER inside `$( … )` command substitution:
# that runs the function in a subshell, the globals die with the subshell,
# and under `set -u` the caller explodes with "unbound variable".
#
# The file part is sent with an explicit `;type=` so the daemon records a
# deterministic media_type instead of relying on libcurl's extension→MIME
# guess (which varies by platform/libmagic). Defaults to application/pdf,
# matching this suite's PDFs.
#
# Args: jar file_path title summary content rating in_reply_to [type] [publish_file]
# Sets UPLOAD_LOCATION + UPLOAD_HEADERS. No `privacy` field (single-tenant);
# publish_file="1" (the 9th arg) sends publish_file=1 to publish the blob.
upload_tcp() {
    local jar="$1" file="$2"
    local title="$3" summary="$4" content="$5"
    local rating="$6" in_reply_to="$7"
    local mime="${8:-application/pdf}"
    local publish_file="${9:-}"

    local form_args=(
        -F            "file=@$file;type=$mime"
        --form-string "name=$title"
        --form-string "summary=$summary"
        --form-string "content=$content"
        --form-string "rating=$rating"
        --form-string "in_reply_to=$in_reply_to"
    )
    if [ "$publish_file" = "1" ]; then
        form_args+=( --form-string "publish_file=1" )
    fi

    local tmp_headers tmp_body
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    # No -L: we want to inspect the 303 + Location, not follow it.
    caddy_curl \
        --cookie "$jar" \
        --dump-header "$tmp_headers" \
        --output "$tmp_body" \
        "${form_args[@]}" \
        "${CADDY_BASE}/upload" >&2
    UPLOAD_HEADERS="$(cat "$tmp_headers")"
    UPLOAD_LOCATION=$(header_value "$UPLOAD_HEADERS" "location")
    if [ -z "$UPLOAD_LOCATION" ]; then
        red "upload_tcp: no Location header in response"
        yellow "headers:"
        cat "$tmp_headers" >&2 || true
        yellow "body (first 30 lines):"
        head -30 "$tmp_body" >&2 || true
        rm -f "$tmp_headers" "$tmp_body"
        return 1
    fi
    rm -f "$tmp_headers" "$tmp_body"
}
