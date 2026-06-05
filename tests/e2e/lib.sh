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
#   sock jar file_path title summary content privacy rating in_reply_to \
#     remote_kind remote_target remote_label
#
# Returns the redirect target (item path) via stdout.
upload() {
    local sock="$1" jar="$2" file="$3"
    local title="$4" summary="$5" content="$6"
    local privacy="$7" rating="$8" in_reply_to="$9"
    local remote_kind="${10:-}" remote_target="${11:-}" remote_label="${12:-}"

    # `--form-string` for everything literal — `-F` interprets `<` and `@`
    # as file-read directives, which mangles HTML content and titles.
    local form_args=(
        -F            "file=@$file"
        --form-string "name=$title"
        --form-string "summary=$summary"
        --form-string "content=$content"
        --form-string "privacy=$privacy"
        --form-string "rating=$rating"
        --form-string "in_reply_to=$in_reply_to"
    )
    if [ -n "$remote_target" ]; then
        form_args+=(
            --form-string "remote_kind=$remote_kind"
            --form-string "remote_target=$remote_target"
            --form-string "remote_label=$remote_label"
        )
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
    local loc
    loc=$(awk 'BEGIN{IGNORECASE=1} /^location:/{$1=""; sub(/^ */,""); print}' \
            "$tmp_headers" | tr -d '\r')
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

# Block until SOCK accepts a connection or TIMEOUT seconds elapse.
wait_for_socket() {
    local sock="$1" timeout="${2:-5}"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ -S "$sock" ] && nc -U -z "$sock" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
        elapsed=$((elapsed + 1))
    done
    red "socket $sock did not come up within ${timeout}s"
    return 1
}
