#!/usr/bin/env bash
# tests/e2e/run.sh — end-to-end test against a local daemon.
#
# Flow (all inside the Nix dev shell, no extra installs):
#   1. fresh data dir + sqlite db
#   2. start the daemon on a temp Unix socket
#   3. log in via session cookie
#   4. upload two generated PDFs (one public, one private), each with
#      an optional rclone gdrive mirror
#   5. upload two reviews — one of the public PDF, one of the private
#      PDF, the latter linking to the private PDF in its content
#   6. verify the rendered HTML contains ratings + hyperlinks
#   7. (optional) verify the PDFs landed in gdrive:annexwyrm-test/
#
# Usage:
#     just test-e2e                  # runs without gdrive sync (default)
#     ANNEXWYRM_E2E_GDRIVE=1 just test-e2e   # also pushes to gdrive
#
# The script cleans up its own data dir + daemon on exit.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/../.." && pwd)"

# shellcheck source=./lib.sh
. "$THIS_DIR/lib.sh"

# ---------------------------------------------------------------------------
#  setup
# ---------------------------------------------------------------------------

TMP="$(mktemp -d -t annexwyrm-e2e.XXXXXX)"
DATA="$TMP/data"
SOCK="$TMP/sock"
LOG="$TMP/daemon.log"
JAR="$TMP/cookies"
USE_GDRIVE="${ANNEXWYRM_E2E_GDRIVE:-0}"
GDRIVE_PREFIX="gdrive:annexwyrm-test"

note "tmp dir:       $TMP"
note "data dir:      $DATA"
note "socket:        $SOCK"
note "use gdrive:    $USE_GDRIVE"

cleanup() {
    if [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
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

# ---------------------------------------------------------------------------
#  build — use the Nix package binary, the exact artifact home-manager
#  deploys. We deliberately do NOT use the dev-shell `just build` here: on
#  this darwin setup the dev shell's NIX_CFLAGS_COMPILE injects a mismatched
#  libcxx `-isystem` ahead of the macOS SDK, which shadows <time.h> and
#  breaks the csrc bridge compile; the sandboxed `nix build .#default` has a
#  clean include path and is what actually ships. Set ANNEXWYRM_BINARY to
#  point the harness at a specific binary (e.g. the deployed store path).
# ---------------------------------------------------------------------------

if [ -n "${ANNEXWYRM_BINARY:-}" ]; then
    BINARY="$ANNEXWYRM_BINARY"
else
    note "building annexwyrm via nix build .#default"
    ( cd "$REPO" && nix build .#default --out-link "$REPO/result" )
    BINARY="$REPO/result/bin/annexwyrm"
fi
if [ ! -x "$BINARY" ]; then
    red "binary not found / not executable: $BINARY"
    exit 1
fi
note "using binary: $BINARY"

# ---------------------------------------------------------------------------
#  init + daemon
# ---------------------------------------------------------------------------

TEST_PASS="testpass"

note "initialising data dir + actor + password"
ANNEXWYRM_DOMAIN="localhost" \
ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" \
ANNEXWYRM_INSTANCE_NAME="alice's e2e archive" \
ANNEXWYRM_PASSWORD="$TEST_PASS" \
ANNEXWYRM_DATA="$DATA" \
    "$BINARY" init "$DATA"

login_row=$(sqlite3 "$DATA/annexwyrm.db" \
    "SELECT 1 FROM local_login LIMIT 1;" || true)
if [ "$login_row" != "1" ]; then
    red "init did not install a login row — $DATA/annexwyrm.db is misconfigured"
    exit 1
fi

note "starting daemon"
ANNEXWYRM_DOMAIN="localhost" \
ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" \
ANNEXWYRM_INSTANCE_NAME="alice's e2e archive" \
ANNEXWYRM_SOCKET="$SOCK" \
ANNEXWYRM_DATA="$DATA" \
    "$BINARY" serve > "$LOG" 2>&1 &
DAEMON_PID=$!

wait_for_socket "$SOCK" 10 || {
    red "daemon failed to start; log:"
    cat "$LOG" >&2
    exit 1
}
note "daemon up (pid $DAEMON_PID)"

# Smoke check: actually talk to it. The accept() loop sometimes takes a
# beat to be ready even after the socket appears; retry for up to 5s.
ready=0
for _ in $(seq 1 10); do
    if curl --silent --output /dev/null --max-time 2 \
            --unix-socket "$SOCK" "http://x/" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" != "1" ]; then
    red "daemon's socket isn't accepting HTTP after 5s"
    yellow "daemon log:"
    cat "$LOG" >&2 || true
    yellow "process state:"
    ps -p "$DAEMON_PID" -o pid,state,command 2>&1 || true
    exit 1
fi
green "  daemon responds"

# ---------------------------------------------------------------------------
#  login
# ---------------------------------------------------------------------------

login "$SOCK" "$JAR" "alice" "$TEST_PASS"

# ---------------------------------------------------------------------------
#  generate the two PDFs
# ---------------------------------------------------------------------------

PDF_PUBLIC="$TMP/public.pdf"
PDF_PRIVATE="$TMP/private.pdf"

note "generating PDFs"
python3 "$THIS_DIR/make-pdf.py" "Public PDF: a serene treatise" > "$PDF_PUBLIC"
python3 "$THIS_DIR/make-pdf.py" "Private PDF: the inner sanctum"  > "$PDF_PRIVATE"

[ -s "$PDF_PUBLIC" ]  || { red "empty public PDF";  exit 1; }
[ -s "$PDF_PRIVATE" ] || { red "empty private PDF"; exit 1; }

# ---------------------------------------------------------------------------
#  upload the public PDF
# ---------------------------------------------------------------------------

note "uploading public PDF"

remote_kind=""; remote_target=""; remote_label=""
if [ "$USE_GDRIVE" = "1" ]; then
    remote_kind="rclone"
    remote_target="$GDRIVE_PREFIX/public.pdf"
    remote_label="alice gdrive (public)"
fi

PUBLIC_PATH=$(upload "$SOCK" "$JAR" "$PDF_PUBLIC" \
    "Public PDF" "" "<p>A document we want everyone to see.</p>" \
    "public" "1" "" \
    "$remote_kind" "$remote_target" "$remote_label")
PUBLIC_URL="http://localhost$PUBLIC_PATH"
green "  public PDF item: $PUBLIC_PATH"

# ---------------------------------------------------------------------------
#  upload the private PDF
# ---------------------------------------------------------------------------

note "uploading private PDF"

if [ "$USE_GDRIVE" = "1" ]; then
    remote_target="$GDRIVE_PREFIX/private.pdf"
    remote_label="alice gdrive (private)"
fi

PRIVATE_PATH=$(upload "$SOCK" "$JAR" "$PDF_PRIVATE" \
    "Private PDF" "" "<p>This stays with alice.</p>" \
    "private" "1" "" \
    "$remote_kind" "$remote_target" "$remote_label")
PRIVATE_URL="http://localhost$PRIVATE_PATH"
green "  private PDF item: $PRIVATE_PATH"

# ---------------------------------------------------------------------------
#  upload review of the public PDF (rating +2)
# ---------------------------------------------------------------------------

note "uploading review of public PDF (+2)"
REVIEW_A_CONTENT="<p>Praise public PDF. A perfectly reasonable read.</p>"
REVIEW_A_PATH=$(upload "$SOCK" "$JAR" "$PDF_PUBLIC" \
    "Review: praise public PDF" "" "$REVIEW_A_CONTENT" \
    "public" "2" "$PUBLIC_URL" \
    "" "" "")
green "  review of public: $REVIEW_A_PATH"

# ---------------------------------------------------------------------------
#  upload review of the private PDF (rating +3) with a hyperlink to it
# ---------------------------------------------------------------------------

note "uploading review of private PDF (+3) with hyperlink"
REVIEW_B_CONTENT="<p>Praise private PDF <em>even more</em> — it builds upon the ideas from <a href=\"$PRIVATE_URL\">privatePDF</a>.</p>"
REVIEW_B_PATH=$(upload "$SOCK" "$JAR" "$PDF_PRIVATE" \
    "Review: praise private PDF even more" "" "$REVIEW_B_CONTENT" \
    "public" "3" "$PRIVATE_URL" \
    "" "" "")
green "  review of private: $REVIEW_B_PATH"

# ---------------------------------------------------------------------------
#  assertions: anonymous browse the public side
# ---------------------------------------------------------------------------

note "ASSERTIONS — anonymous browser"

note "  homepage shows both reviews + ratings"
HOME_HTML=$(fetch_html_anon "$SOCK" "/")
assert_grep "$HOME_HTML" "Review: praise public PDF"            "review A title"
assert_grep "$HOME_HTML" "Review: praise private PDF even more" "review B title"
assert_grep "$HOME_HTML" '\[+2\]' "rating badge +2"
assert_grep "$HOME_HTML" '\[+3\]' "rating badge +3"
assert_grep "$HOME_HTML" 'class="rating positive"' "positive-rating css class"

note "  review B page contains the hyperlink to the private PDF"
REVIEW_B_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_B_PATH")
assert_grep "$REVIEW_B_HTML" "href=\"$PRIVATE_URL\""    "hyperlink to private PDF"
assert_grep "$REVIEW_B_HTML" "★★★"                     "three full stars on review B"
assert_grep "$REVIEW_B_HTML" "review of"                "review-of badge"

note "  review A page rates +2 and has stars"
REVIEW_A_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_A_PATH")
assert_grep "$REVIEW_A_HTML" "★★"                      "two full stars on review A"
assert_grep "$REVIEW_A_HTML" "$PUBLIC_URL"             "review A links to public PDF"

note "  private PDF is 404 to the anonymous visitor"
assert_status "$SOCK" "$PRIVATE_PATH" 404

note "  public PDF is reachable anonymously"
assert_status "$SOCK" "$PUBLIC_PATH" 200

# ---------------------------------------------------------------------------
#  Google Drive sync verification (opt-in)
# ---------------------------------------------------------------------------

if [ "$USE_GDRIVE" = "1" ]; then
    note "ASSERTIONS — Google Drive landed both PDFs"
    listing=$(rclone lsf --files-only "$GDRIVE_PREFIX/" 2>&1 || true)
    assert_grep "$listing" "public.pdf"  "gdrive: public.pdf"
    assert_grep "$listing" "private.pdf" "gdrive: private.pdf"
fi

green ""
green "=========================================="
green "  e2e passed.  data dir: $DATA"
green "  daemon log: $LOG"
green "=========================================="
