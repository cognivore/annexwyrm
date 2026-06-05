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

# ===========================================================================
#  PUBLISH / UNPUBLISH federation-emission journey
#
#  Drives the two outbox-firing endpoints with the already-logged-in session
#  from above, and asserts all four observable surfaces at each step: the HTTP
#  client view, the daemon log line (stderr → $LOG), the `item` row transition,
#  and the exact `activity` / `delivery` row state. Continuation of the same
#  daemon/socket/jar/DB — no new fixture. See tests/e2e/SPEC-publish.md.
# ===========================================================================

note "=== PUBLISH / UNPUBLISH federation journey ==="

# --- §3: subject + identities, fixed once -------------------------------
SUBJECT_PATH="$PRIVATE_PATH"          # /items/<hex>
SUBJECT_URL="$PRIVATE_URL"            # http://localhost/items/<hex> — the stored id
ACTOR_URL="http://localhost/users/alice"   # local-actor-url() with ANNEXWYRM_USERNAME=alice
DB="$DATA/annexwyrm.db"

# --- Step P0: baseline (capture deltas, not absolutes) ------------------
note "  P0 — baseline (activity/delivery counts, privacy, zero followers)"
ACT_BEFORE=$(sqlite3 "$DB" "SELECT count(*) FROM activity;")
DEL_BEFORE=$(sqlite3 "$DB" "SELECT count(*) FROM delivery;")
note "    activity baseline = $ACT_BEFORE, delivery baseline = $DEL_BEFORE"
assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" \
    "private" "subject starts private"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "0" "no pre-existing Create"
assert_sql "$DB" "SELECT count(*) FROM follow WHERE target_id='$ACTOR_URL' AND state='accepted';" \
    "0" "zero accepted followers (single-actor instance)"

# --- Step P1: PUBLISH — 303, log line, Create row, zero deliveries ------
note "  P1 — POST $SUBJECT_PATH/publish (session cookie, empty body, no redirect-follow)"
P1_RESULT=$(post_action "$SOCK" "$JAR" "$SUBJECT_PATH/publish")
P1_STATUS="${P1_RESULT%%$'\t'*}"
P1_LOC="${P1_RESULT#*$'\t'}"

# (a) client sees a 303 to the item path
if [ "$P1_STATUS" != "303" ]; then
    red "publish: expected status 303, got $P1_STATUS (a 403/404 here means the auth gate or load-item path fired)"
    exit 1
fi
green "  ✓ publish → 303"
if [ "$P1_LOC" != "$SUBJECT_PATH" ]; then
    red "publish: expected Location [$SUBJECT_PATH], got [$P1_LOC]"
    exit 1
fi
green "  ✓ publish Location = $SUBJECT_PATH"

# (b) daemon logged outbox/publish with recipients=0 (the literal zero-delivery mirror)
assert_log_grep "$LOG" \
    '^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Create recipients=0' \
    "publish emission"

# (c) exactly one Create activity row for the subject, shaped correctly
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "1" "one Create activity for subject"
assert_sql "$DB" "SELECT actor_id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "$ACTOR_URL" "Create actor = local actor"
assert_sql "$DB" "SELECT object_id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "$SUBJECT_URL" "Create object_id = item id"
assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "0" "Create is outbound"
assert_sql "$DB" "SELECT id GLOB 'http://localhost/activities/*' FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "1" "Create id is minted activity URL"
assert_sql "$DB" "SELECT raw LIKE '%\"type\":\"Create\"%' AND raw LIKE '%$SUBJECT_URL%' FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" \
    "1" "Create raw contains type+object id"

# (c) delivery rows == follower-inbox count == EXACTLY 0 (the headline invariant)
assert_sql "$DB" "SELECT count(*) FROM delivery;" \
    "$DEL_BEFORE" "publish queued zero deliveries (delta == 0)"
CREATE_AID=$(sqlite3 "$DB" \
    "SELECT id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';")
assert_sql "$DB" "SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID';" \
    "0" "exactly zero deliveries for the Create activity"

# --- Step P2: item row transitioned to public --------------------------
note "  P2 — item row is now public (same row, updated_at advanced)"
assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" \
    "public" "subject is now public"
assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL';" \
    "1" "still exactly one item row"
# `>=`, not `>`: timestamps are ISO-8601 at one-second granularity, so when
# publish lands in the same wall-clock second as the original upload the two
# are equal — a strict `>` made this assertion flaky (it raced). The privacy
# flip below is the real proof publish did its work; this just guards that
# updated_at is never stamped *behind* published_at.
assert_sql "$DB" "SELECT updated_at >= published_at FROM item WHERE id='$SUBJECT_URL';" \
    "1" "updated_at not behind published_at on publish"

# --- Step P3: the item is now publicly visible over HTTP ----------------
note "  P3 — anonymous GET now 200 + public-state markers"
assert_status "$SOCK" "$SUBJECT_PATH" 200
PUB_HTML=$(fetch_html_anon "$SOCK" "$SUBJECT_PATH")
assert_grep "$PUB_HTML" '<span class="privacy">public</span>' "privacy meta shows public"
assert_grep "$PUB_HTML" '/unpublish" method="post"' "publish state offers the unpublish action"
assert_grep "$PUB_HTML" 'Private PDF' "subject title still renders"
# negative marker: the publish form MUST be gone (proves the new state, not a cache)
if printf '%s' "$PUB_HTML" | grep -q '/publish" method="post"'; then
    red "published item still shows a publish form"
    printf '%s\n' "$PUB_HTML" | head -40 >&2
    exit 1
fi
green "  ✓ no stale publish form on the published page"
# (b) read render is pure (no log line); assert the daemon survived the request
kill -0 "$DAEMON_PID" || { red "daemon died serving the published item page"; exit 1; }
green "  ✓ daemon still alive after public render"

# --- Step U1: UNPUBLISH — 303, delete log, Delete row, zero deliveries --
note "  U1 — POST $SUBJECT_PATH/unpublish (emit-delete runs BEFORE revert-to-private)"
U1_RESULT=$(post_action "$SOCK" "$JAR" "$SUBJECT_PATH/unpublish")
U1_STATUS="${U1_RESULT%%$'\t'*}"
U1_LOC="${U1_RESULT#*$'\t'}"

# (a) client sees a 303 to the item path
if [ "$U1_STATUS" != "303" ]; then
    red "unpublish: expected status 303, got $U1_STATUS"
    exit 1
fi
green "  ✓ unpublish → 303"
if [ "$U1_LOC" != "$SUBJECT_PATH" ]; then
    red "unpublish: expected Location [$SUBJECT_PATH], got [$U1_LOC]"
    exit 1
fi
green "  ✓ unpublish Location = $SUBJECT_PATH"

# (b) daemon logged outbox/delete — id ONLY, line ends right after it (no recipients=)
assert_log_grep "$LOG" \
    '^\[info\] outbox/delete id=http://localhost/activities/[0-9a-f]+$' \
    "delete emission"

# (c) exactly one Delete activity row for the subject, shaped correctly
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" \
    "1" "one Delete activity for subject"
assert_sql "$DB" "SELECT actor_id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" \
    "$ACTOR_URL" "Delete actor = local actor"
assert_sql "$DB" "SELECT object_id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" \
    "$SUBJECT_URL" "Delete object_id = item id"
assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" \
    "0" "Delete is outbound"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE object_id='$SUBJECT_URL' AND type IN ('Create','Delete');" \
    "2" "both Create and Delete recorded for subject"

# (c) delivery rows for the Delete == EXACTLY 0; global total still baseline
DELETE_AID=$(sqlite3 "$DB" \
    "SELECT id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';")
assert_sql "$DB" "SELECT count(*) FROM delivery WHERE activity_id='$DELETE_AID';" \
    "0" "exactly zero deliveries for the Delete activity"
assert_sql "$DB" "SELECT count(*) FROM delivery;" \
    "$DEL_BEFORE" "delivery table unchanged across publish+unpublish"

# --- Step U2: item reverted to private AND the row survives -------------
note "  U2 — item reverted to private; row survives (NO local tombstone)"
assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL';" \
    "1" "item row survives unpublish (no local tombstone)"
assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" \
    "private" "subject reverted to private"
assert_sql "$DB" "SELECT name FROM item WHERE id='$SUBJECT_URL';" \
    "Private PDF" "item name preserved through unpublish"
assert_sql "$DB" "SELECT updated_at >= published_at FROM item WHERE id='$SUBJECT_URL';" \
    "1" "updated_at advanced on unpublish"

# --- Step U3: hidden from anonymous HTTP again, with no leak ------------
note "  U3 — anon GET 404 (no leak); owner still 200 (authorization, not deletion)"
assert_status "$SOCK" "$SUBJECT_PATH" 404
GONE_HTML=$(fetch_html_anon "$SOCK" "$SUBJECT_PATH")
assert_grep "$GONE_HTML" "no such item" "404 body says no such item"
if printf '%s' "$GONE_HTML" | grep -q 'Private PDF'; then
    red "404 page leaked the private item's title"
    printf '%s\n' "$GONE_HTML" | head -40 >&2
    exit 1
fi
if printf '%s' "$GONE_HTML" | grep -q 'This stays with alice'; then
    red "404 page leaked the private item's content"
    printf '%s\n' "$GONE_HTML" | head -40 >&2
    exit 1
fi
green "  ✓ 404 page leaks neither title nor content"
# owner can still see it — authorization, not deletion
OWNER_CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --unix-socket "$SOCK" --cookie "$JAR" "http://x$SUBJECT_PATH")
if [ "$OWNER_CODE" != "200" ]; then
    red "owner GET of unpublished item: expected 200, got $OWNER_CODE (row may have been destroyed)"
    exit 1
fi
green "  ✓ owner still sees the private item → 200"
OWNER_HTML=$(fetch_html "$SOCK" "$JAR" "$SUBJECT_PATH")
assert_grep "$OWNER_HTML" '/publish" method="post"' "owner sees publish action again (item is private)"
# (b) read render is pure; assert only that the daemon is still alive
kill -0 "$DAEMON_PID" || { red "daemon died serving the unpublished item page"; exit 1; }
green "  ✓ daemon still alive after re-hidden render"
# (c) re-affirm survival from the DB side after the HTTP round trip
assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL' AND privacy='private';" \
    "1" "private item persists after unpublish round-trip"

# --- §5: authorization edge — the owner gate is real --------------------
note "  AUTH — anonymous publish/unpublish forbidden (403 + 'login required')"
ANON_PUB_CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --unix-socket "$SOCK" --request POST --data '' "http://x$SUBJECT_PATH/publish")
if [ "$ANON_PUB_CODE" != "403" ]; then
    red "anon publish: expected 403, got $ANON_PUB_CODE (the owner gate did not fire)"
    exit 1
fi
green "  ✓ anon publish → 403"
ANON_PUB_BODY=$(curl --silent --unix-socket "$SOCK" --request POST --data '' \
    "http://x$SUBJECT_PATH/publish")
assert_grep "$ANON_PUB_BODY" "login required" "anon publish refused"
ANON_UNPUB_BODY=$(curl --silent --unix-socket "$SOCK" --request POST --data '' \
    "http://x$SUBJECT_PATH/unpublish")
assert_grep "$ANON_UNPUB_BODY" "login required" "anon unpublish refused"
# (c) the anon attempts emitted no activities and did not flip privacy
assert_sql "$DB" "SELECT count(*) FROM activity WHERE object_id='$SUBJECT_URL' AND type IN ('Create','Delete');" \
    "2" "anon attempts emitted no activities"
assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" \
    "private" "anon publish did not change privacy"

green ""
green "=========================================="
green "  e2e passed.  data dir: $DATA"
green "  daemon log: $LOG"
green "=========================================="
