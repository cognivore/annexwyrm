#!/usr/bin/env bash
# tests/e2e/run.sh — end-to-end test against a local daemon (Unix socket).
#
# The single-tenant file-publication model (tests/e2e/SPEC-file-publication.md):
# every item is ALWAYS public and federates immediately (Create on upload);
# the only gate is the FILE BLOB. The default is "archived" — the blob goes
# only to the encrypted archive remote, the item page shows no download link,
# and nothing about the blob appears in the federated object. `publish-file`
# (at upload via a checkbox, or later via POST /items/<id>/publish-file) also
# copies the blob to the public remote, mints a download URL, stores it,
# renders it, adds it to the AP url[], and emits an Update.
#
# Hermetic seam: rclone treats a plain absolute path as the local backend,
# so both remotes point at temp dirs and we assert REAL BYTES land there.
# blob-public-url cannot mint a URL for a local path, so ANNEXWYRM_PUBLIC_URL_BASE
# supplies a constructed URL (http://example.test/dl/<slug>). The real
# encrypted-at-rest / gdrive URL shapes are asserted only behind
# ANNEXWYRM_E2E_GDRIVE=1.
#
# Usage:
#     just test-e2e                          # hermetic (default)
#     ANNEXWYRM_E2E_GDRIVE=1 just test-e2e   # also exercises the real remotes
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

# The hermetic blob backends (local-backend temp dirs) and the public-URL
# seam. The gdrive-gated variant overrides these with real remotes and
# unsets the URL base so the real `rclone link` path runs.
if [ "$USE_GDRIVE" = "1" ]; then
    ARCHIVE_REMOTE="gdrive-crypt:annexwyrm-test"
    PUBLIC_REMOTE="gdrive:annexwyrm-public-test"
    PUBLIC_URL_BASE=""
else
    ARCHIVE_REMOTE="$TMP/archive"
    PUBLIC_REMOTE="$TMP/public"
    PUBLIC_URL_BASE="http://example.test/dl"
    mkdir -p "$ARCHIVE_REMOTE" "$PUBLIC_REMOTE"
fi

note "tmp dir:        $TMP"
note "data dir:       $DATA"
note "socket:         $SOCK"
note "use gdrive:     $USE_GDRIVE"
note "archive remote: $ARCHIVE_REMOTE"
note "public remote:  $PUBLIC_REMOTE"
note "public url base:${PUBLIC_URL_BASE:-(rclone link)}"

cleanup() {
    if [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [ -n "${FAIL_PID:-}" ] && kill -0 "$FAIL_PID" 2>/dev/null; then
        kill "$FAIL_PID" 2>/dev/null || true
        wait "$FAIL_PID" 2>/dev/null || true
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
#  build — the Nix package binary (see the long note in the old suite: the
#  dev-shell `just build` is broken on this darwin host; nix build .#default
#  is what ships). ANNEXWYRM_BINARY overrides.
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

# A fresh init MUST produce an item table with the file-publication columns
# and NO privacy column (the model's first definition-of-done clause).
COLS=$(sqlite3 "$DATA/annexwyrm.db" "PRAGMA table_info(item);" | awk -F'|' '{print $2}' | tr '\n' ' ')
note "fresh item columns: $COLS"
case "$COLS" in
    *file_published*file_public_url*file_view_url*) green "  ✓ file-publication columns present" ;;
    *) red "fresh schema missing file-publication columns: $COLS"; exit 1 ;;
esac
if printf '%s' "$COLS" | grep -qw "privacy"; then
    red "fresh schema still has a privacy column (it must be dropped from fresh init)"
    exit 1
fi
green "  ✓ fresh schema has no privacy column"

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
ANNEXWYRM_ARCHIVE_REMOTE="$ARCHIVE_REMOTE" \
ANNEXWYRM_PUBLIC_REMOTE="$PUBLIC_REMOTE" \
ANNEXWYRM_PUBLIC_URL_BASE="$PUBLIC_URL_BASE" \
ANNEXWYRM_SERVE_DRAIN=0 \
    "$BINARY" serve > "$LOG" 2>&1 &
DAEMON_PID=$!

wait_for_socket "$SOCK" 10 || {
    red "daemon failed to start; log:"
    cat "$LOG" >&2
    exit 1
}
note "daemon up (pid $DAEMON_PID)"

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
    yellow "daemon log:"; cat "$LOG" >&2 || true
    exit 1
fi
green "  daemon responds"

# ---------------------------------------------------------------------------
#  login
# ---------------------------------------------------------------------------

login "$SOCK" "$JAR" "alice" "$TEST_PASS"

# ---------------------------------------------------------------------------
#  generate the PDFs
# ---------------------------------------------------------------------------

PDF_ONE="$TMP/one.pdf"
PDF_TWO="$TMP/two.pdf"

note "generating PDFs"
python3 "$THIS_DIR/make-pdf.py" "PDF one: a serene treatise" > "$PDF_ONE"
python3 "$THIS_DIR/make-pdf.py" "PDF two: the inner sanctum"  > "$PDF_TWO"

[ -s "$PDF_ONE" ] || { red "empty PDF one"; exit 1; }
[ -s "$PDF_TWO" ] || { red "empty PDF two"; exit 1; }

DB="$DATA/annexwyrm.db"
ACTOR_URL="http://localhost/users/alice"   # local-actor-url() with ANNEXWYRM_USERNAME=alice

# ===========================================================================
#  Step A — upload ARCHIVED (the default). The review federates (Create), but
#  the file goes only to the archive remote and the page hides the download.
# ===========================================================================

note "=== Step A — upload archived PDF (default, no publish_file) ==="
ARCH_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" \
    "Archived PDF" "" "<p>secret research; key results below.</p>" "99" "")
ARCH_URL="http://localhost$ARCH_PATH"
ARCH_SLUG="${ARCH_PATH##*/}"
green "  archived item: $ARCH_PATH (slug $ARCH_SLUG)"

# (a) screen — the review renders to anon (200), shows the archived line, has
#     NO download anchor.
assert_status "$SOCK" "$ARCH_PATH" 200
A_HTML=$(fetch_html_anon "$SOCK" "$ARCH_PATH")
assert_grep "$A_HTML" "secret research; key results below." "review body renders to anon"
assert_grep "$A_HTML" "file archived, not published"         "archived file-state line"
if printf '%s' "$A_HTML" | grep -q 'class="download"'; then
    red "archived item page leaked a download anchor"
    printf '%s\n' "$A_HTML" | head -40 >&2
    exit 1
fi
green "  ✓ no download anchor on the archived page"

# (b) daemon log — upload/done file_published=0 AND a Create emission.
assert_log_grep "$LOG" \
    "^\[info\] upload/done id=$ARCH_URL size=[0-9]+ file_published=0\$" \
    "archived upload/done"
assert_log_grep "$LOG" \
    '^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Create recipients=0' \
    "upload emits Create (recipients=0, no followers)"

# (c) DB — file_published=0, no URL, exactly one Create for the item.
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$ARCH_URL';" \
    "0" "archived item file_published=0"
assert_sql "$DB" "SELECT file_public_url IS NULL OR file_public_url='' FROM item WHERE id='$ARCH_URL';" \
    "1" "archived item has no public URL"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$ARCH_URL';" \
    "1" "exactly one Create for the archived item"
assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Create' AND object_id='$ARCH_URL';" \
    "0" "the Create is outbound"

# (c) on-disk bytes — landed ONLY in the archive backend; nothing public yet.
if [ "$USE_GDRIVE" = "1" ]; then
    note "  (gdrive) archive bytes asserted by the gated block below"
else
    [ -f "$ARCHIVE_REMOTE/$ARCH_SLUG" ] || { red "archive blob missing on disk"; exit 1; }
    green "  ✓ archive blob present at $ARCHIVE_REMOTE/$ARCH_SLUG"
    cmp -s "$ARCHIVE_REMOTE/$ARCH_SLUG" "$PDF_ONE" \
        && green "  ✓ archive blob bytes == plaintext (local backend)" \
        || { red "archive blob bytes differ from the uploaded PDF"; exit 1; }
    if [ -n "$(ls -A "$PUBLIC_REMOTE")" ]; then
        red "public remote is non-empty after an ARCHIVED upload — blob leaked"
        ls -la "$PUBLIC_REMOTE" >&2
        exit 1
    fi
    green "  ✓ public remote empty after archived upload"
fi

# ===========================================================================
#  Step B — publish-file later. Copies to the public remote, mints + stores
#  the URL, renders the download link, and emits an Update.
# ===========================================================================

note "=== Step B — POST $ARCH_PATH/publish-file ==="
B_RESULT=$(post_action "$SOCK" "$JAR" "$ARCH_PATH/publish-file")
B_STATUS="${B_RESULT%%$'\t'*}"
B_LOC="${B_RESULT#*$'\t'}"

# (a) screen — 303 → the item, then the published download link is present
#     and the archived line is gone.
[ "$B_STATUS" = "303" ] || { red "publish-file: expected 303, got $B_STATUS"; exit 1; }
green "  ✓ publish-file → 303"
[ "$B_LOC" = "$ARCH_PATH" ] || { red "publish-file: expected Location $ARCH_PATH, got $B_LOC"; exit 1; }
green "  ✓ publish-file Location = $ARCH_PATH"

B_HTML=$(fetch_html_anon "$SOCK" "$ARCH_PATH")
if [ "$USE_GDRIVE" = "1" ]; then
    assert_grep "$B_HTML" 'class="download" href="https://drive.google.com/uc?export=download' \
        "published download link (gdrive uc?export=download form)"
else
    assert_grep "$B_HTML" "class=\"download\" href=\"http://example.test/dl/$ARCH_SLUG\"" \
        "published download link (hermetic constructed URL)"
fi
if printf '%s' "$B_HTML" | grep -q 'file archived, not published'; then
    red "published item page still shows the archived line"
    exit 1
fi
green "  ✓ archived line gone on the published page"

# (b) daemon log — publish-file emits Update (recipients=0).
assert_log_grep "$LOG" \
    '^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Update recipients=0' \
    "publish-file emits Update (recipients=0)"

# (c) DB — file_published=1, URL stored, exactly one Update whose raw carries
#     the URL, the Create still present, zero deliveries.
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$ARCH_URL';" \
    "1" "item now file_published=1"
if [ "$USE_GDRIVE" = "1" ]; then
    assert_sql "$DB" "SELECT file_public_url LIKE 'https://drive.google.com/uc?export=download%' FROM item WHERE id='$ARCH_URL';" \
        "1" "public URL is the gdrive uc?export=download form"
    assert_sql "$DB" "SELECT file_view_url LIKE 'https://drive.google.com/open?id=%' FROM item WHERE id='$ARCH_URL';" \
        "1" "view URL is the gdrive open?id form"
    assert_sql "$DB" "SELECT raw LIKE '%uc?export=download%' FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
        "1" "Update raw carries the download URL"
else
    assert_sql "$DB" "SELECT file_public_url FROM item WHERE id='$ARCH_URL';" \
        "http://example.test/dl/$ARCH_SLUG" "public URL is the constructed hermetic URL"
    assert_sql "$DB" "SELECT raw LIKE '%http://example.test/dl/%' FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
        "1" "Update raw carries the download URL"
fi
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
    "1" "exactly one Update for the item"
assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
    "0" "the Update is outbound"
assert_sql "$DB" "SELECT actor_id FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
    "$ACTOR_URL" "Update actor = local actor"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$ARCH_URL';" \
    "1" "the Create from Step A still exists (publish-file does not retract it)"
UPDATE_AID=$(sqlite3 "$DB" "SELECT id FROM activity WHERE type='Update' AND object_id='$ARCH_URL';")
assert_sql "$DB" "SELECT count(*) FROM delivery WHERE activity_id='$UPDATE_AID';" \
    "0" "zero deliveries for the Update (no followers)"

# (c) on-disk bytes — now present in the public backend; archive untouched.
if [ "$USE_GDRIVE" != "1" ]; then
    [ -f "$PUBLIC_REMOTE/$ARCH_SLUG" ] || { red "public blob missing after publish-file"; exit 1; }
    green "  ✓ public blob present at $PUBLIC_REMOTE/$ARCH_SLUG"
    [ -f "$ARCHIVE_REMOTE/$ARCH_SLUG" ] || { red "archive blob vanished after publish-file"; exit 1; }
    green "  ✓ archive blob retained after publish-file"
fi

# ===========================================================================
#  Step C — publish-file idempotency. A second POST is a harmless no-op, NOT
#  a double Update.
# ===========================================================================

note "=== Step C — publish-file idempotency ==="
C_RESULT=$(post_action "$SOCK" "$JAR" "$ARCH_PATH/publish-file")
C_STATUS="${C_RESULT%%$'\t'*}"
[ "$C_STATUS" = "303" ] || { red "second publish-file: expected 303, got $C_STATUS"; exit 1; }
green "  ✓ second publish-file → 303"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$ARCH_URL';" \
    "1" "still exactly one Update (no double emission)"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$ARCH_URL';" \
    "1" "file_published still 1 after a second publish-file"

# ===========================================================================
#  Step D — owner gate. An anonymous publish-file is forbidden and changes
#  nothing.
# ===========================================================================

note "=== Step D — owner gate (anonymous publish-file) ==="
# Use the as-yet-unpublished PDF two so the negative is meaningful. Upload it
# archived first.
TWO_PATH=$(upload "$SOCK" "$JAR" "$PDF_TWO" \
    "Second PDF" "" "<p>another archived review.</p>" "99" "")
TWO_URL="http://localhost$TWO_PATH"
ANON_CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --unix-socket "$SOCK" --request POST --data '' "http://x$TWO_PATH/publish-file")
[ "$ANON_CODE" = "403" ] || { red "anon publish-file: expected 403, got $ANON_CODE"; exit 1; }
green "  ✓ anon publish-file → 403"
ANON_BODY=$(curl --silent --unix-socket "$SOCK" --request POST --data '' "http://x$TWO_PATH/publish-file")
assert_grep "$ANON_BODY" "login required" "anon publish-file refused"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$TWO_URL';" \
    "0" "anon publish-file did NOT flip file_published"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$TWO_URL';" \
    "0" "anon publish-file emitted no Update"

# ===========================================================================
#  reviews — the heart of the site: a rating + a hyperlink to another item.
#  Reviews are pure-Note items (the uploaded "file" is the same PDF here, but
#  what matters is that they federate immediately and render to anon).
# ===========================================================================

note "=== reviews — uploaded with ratings + in_reply_to ==="
REVIEW_A_CONTENT="<p>Praise PDF one. A perfectly reasonable read.</p>"
REVIEW_A_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" \
    "Review: praise PDF one" "" "$REVIEW_A_CONTENT" "2" "$ARCH_URL")
green "  review A (+2): $REVIEW_A_PATH"

REVIEW_B_CONTENT="<p>Praise PDF two <em>even more</em> — it builds upon <a href=\"$TWO_URL\">PDF two</a>.</p>"
REVIEW_B_PATH=$(upload "$SOCK" "$JAR" "$PDF_TWO" \
    "Review: praise PDF two even more" "" "$REVIEW_B_CONTENT" "3" "$TWO_URL")
green "  review B (+3): $REVIEW_B_PATH"

# ---------------------------------------------------------------------------
#  anonymous browsing — every item is public; the home list shows them ALL.
# ---------------------------------------------------------------------------

note "=== anonymous browser ==="
note "  homepage shows every item + ratings (no privacy filter)"
HOME_HTML=$(fetch_html_anon "$SOCK" "/")
assert_grep "$HOME_HTML" "Review: praise PDF one"            "review A title on home"
assert_grep "$HOME_HTML" "Review: praise PDF two even more"  "review B title on home"
assert_grep "$HOME_HTML" "Archived PDF"                      "archived item appears on home (no WHERE filter)"
assert_grep "$HOME_HTML" '\[+2\]' "rating badge +2"
assert_grep "$HOME_HTML" '\[+3\]' "rating badge +3"
assert_grep "$HOME_HTML" 'class="rating positive"' "positive-rating css class"
# The published item carries the [file] marker; no privacy word ever appears.
assert_grep "$HOME_HTML" '\[file\]' "published item shows the [file] marker"
if printf '%s' "$HOME_HTML" | grep -qiE 'class="meta">[^<]*· (public|private|unlisted|followers)'; then
    red "home list still renders a privacy word"
    exit 1
fi
green "  ✓ no privacy word on the home list"

note "  review B page contains the hyperlink + three stars + review-of"
REVIEW_B_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_B_PATH")
assert_grep "$REVIEW_B_HTML" "href=\"$TWO_URL\"" "hyperlink to PDF two"
assert_grep "$REVIEW_B_HTML" "★★★"               "three full stars on review B"
assert_grep "$REVIEW_B_HTML" "review of"          "review-of badge"

note "  review A page rates +2 and links to PDF one"
REVIEW_A_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_A_PATH")
assert_grep "$REVIEW_A_HTML" "★★"        "two full stars on review A"
assert_grep "$REVIEW_A_HTML" "$ARCH_URL" "review A links to PDF one"

note "  every item is reachable anonymously (no 404-for-private)"
assert_status "$SOCK" "$ARCH_PATH" 200
assert_status "$SOCK" "$TWO_PATH"  200
assert_status "$SOCK" "$REVIEW_A_PATH" 200

# ---------------------------------------------------------------------------
#  Google Drive sync verification (opt-in)
# ---------------------------------------------------------------------------

if [ "$USE_GDRIVE" = "1" ]; then
    note "=== Google Drive — archived blob encrypted-at-rest; public blob fetchable ==="
    # The archived blob lives in the crypt remote; its raw object on the
    # underlying gdrive is NOT the plaintext. We can't trivially diff bytes
    # here, but we can assert the listing + that the public copy 200s anon.
    arch_listing=$(rclone lsf --files-only "$ARCHIVE_REMOTE/" 2>&1 || true)
    assert_grep "$arch_listing" "$ARCH_SLUG" "gdrive crypt: archive holds the slug"
    pub_url=$(sqlite3 "$DB" "SELECT file_view_url FROM item WHERE id='$ARCH_URL';")
    note "  fetching minted public URL anonymously: $pub_url"
    pub_code=$(curl -sL --output /dev/null --write-out '%{http_code}' "$pub_url" || true)
    [ "$pub_code" = "200" ] && green "  ✓ public URL fetches 200 anonymously" \
        || { red "public URL did not fetch 200 (got $pub_code)"; exit 1; }
fi

# ===========================================================================
#  Step E — archive-put failure (forbid-if-it-didn't-crash control). With the
#  archive remote pointed at a FILE (rclone rcat fails), an upload MUST 5xx,
#  save no item, and emit no Create. This proves the mandatory-archive-put
#  contract is real and not a swallowed error. Run on a SEPARATE daemon so the
#  broken remote does not poison the main suite.
# ===========================================================================

note "=== Step E — archive-put failure → 5xx, no item, no Create ==="
FAIL_TMP="$TMP/fail"
FAIL_DATA="$FAIL_TMP/data"; FAIL_SOCK="$FAIL_TMP/sock"; FAIL_LOG="$FAIL_TMP/daemon.log"
FAIL_JAR="$FAIL_TMP/cookies"; FAIL_PUB="$FAIL_TMP/public"
BAD_ARCHIVE="$FAIL_TMP/not-a-dir"
mkdir -p "$FAIL_DATA" "$FAIL_PUB"
printf 'i am a file, not a directory\n' > "$BAD_ARCHIVE"

ANNEXWYRM_DOMAIN="localhost" ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" ANNEXWYRM_INSTANCE_NAME="fail" \
ANNEXWYRM_PASSWORD="$TEST_PASS" ANNEXWYRM_DATA="$FAIL_DATA" \
    "$BINARY" init "$FAIL_DATA" >/dev/null 2>&1

ANNEXWYRM_DOMAIN="localhost" ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" ANNEXWYRM_INSTANCE_NAME="fail" \
ANNEXWYRM_SOCKET="$FAIL_SOCK" ANNEXWYRM_DATA="$FAIL_DATA" \
ANNEXWYRM_ARCHIVE_REMOTE="$BAD_ARCHIVE" ANNEXWYRM_PUBLIC_REMOTE="$FAIL_PUB" \
ANNEXWYRM_PUBLIC_URL_BASE="http://example.test/dl" ANNEXWYRM_SERVE_DRAIN=0 \
    "$BINARY" serve > "$FAIL_LOG" 2>&1 &
FAIL_PID=$!
wait_for_socket "$FAIL_SOCK" 10 || { red "fail-daemon did not start"; cat "$FAIL_LOG" >&2; exit 1; }
for _ in $(seq 1 10); do
    curl --silent --output /dev/null --max-time 2 --unix-socket "$FAIL_SOCK" "http://x/" >/dev/null 2>&1 && break
    sleep 0.5
done
login "$FAIL_SOCK" "$FAIL_JAR" "alice" "$TEST_PASS"

FAIL_CODE=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --unix-socket "$FAIL_SOCK" --cookie "$FAIL_JAR" \
    -F "file=@$PDF_ONE;type=application/pdf" \
    --form-string "name=Doomed" --form-string "summary=" \
    --form-string "content=<p>this should never persist</p>" \
    --form-string "rating=99" --form-string "in_reply_to=" \
    "http://x/upload")
case "$FAIL_CODE" in
    5*) green "  ✓ archive-put failure → $FAIL_CODE (5xx)" ;;
    *)  red "archive-put failure: expected 5xx, got $FAIL_CODE"; cat "$FAIL_LOG" >&2; exit 1 ;;
esac
assert_log_grep "$FAIL_LOG" \
    '^\[error\] upload/archive-put-failed' \
    "archive-put failure logged at error"
FAIL_DB="$FAIL_DATA/annexwyrm.db"
assert_sql "$FAIL_DB" "SELECT count(*) FROM item WHERE name='Doomed';" \
    "0" "no item row for the doomed upload"
assert_sql "$FAIL_DB" "SELECT count(*) FROM activity;" \
    "0" "no activity (no Create) for the doomed upload"
kill "$FAIL_PID" 2>/dev/null || true; wait "$FAIL_PID" 2>/dev/null || true
FAIL_PID=""

# ===========================================================================
#  Step F — MIGRATED-DB write path. Every other step runs on a fresh DB,
#  which is exactly how the first real prod upload broke: the old schema's
#  `privacy TEXT NOT NULL` (no default) column survived migration as a dead
#  column, the new save-item INSERT didn't supply it, the exec return was
#  discarded, and the item row silently vanished while the Create activity
#  and archived blob persisted. This step builds a faithful OLD-shape DB,
#  lets init migrate it (which must DROP the dead column), then drives one
#  real upload through the daemon and asserts the item row EXISTS.
# ===========================================================================
note "=== Step F — migrated old-schema DB accepts uploads ==="
MIG_DATA="$TMP/mig-data"; MIG_SOCK="$TMP/mig-sock"; MIG_LOG="$TMP/mig.log"
MIG_JAR="$TMP/mig-jar"; mkdir -p "$MIG_DATA"
# Old-shape item table: privacy TEXT NOT NULL + the old index, pre-dating
# the file_* columns. (Faithful to the pre-file-publication schema.)
sqlite3 "$MIG_DATA/annexwyrm.db" <<'OLDSQL'
CREATE TABLE item (
  id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, object_type TEXT NOT NULL,
  privacy TEXT NOT NULL, name TEXT NOT NULL, summary TEXT, content TEXT,
  media_type TEXT, byte_size INTEGER, sha256 TEXT,
  rating INTEGER, in_reply_to TEXT,
  published_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX item_privacy_published ON item(privacy, published_at);
OLDSQL
ANNEXWYRM_DOMAIN="localhost" ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" ANNEXWYRM_INSTANCE_NAME="mig e2e" \
ANNEXWYRM_PASSWORD="$TEST_PASS" ANNEXWYRM_DATA="$MIG_DATA" \
    "$BINARY" init "$MIG_DATA" >/dev/null 2>&1
MIG_COLS=$(sqlite3 "$MIG_DATA/annexwyrm.db" "PRAGMA table_info(item);" | awk -F'|' '{print $2}' | tr '\n' ' ')
if printf '%s' "$MIG_COLS" | grep -qw "privacy"; then
    red "migration kept the dead privacy column (NOT NULL would break inserts): $MIG_COLS"
    exit 1
fi
green "  ✓ migration DROPPED the dead privacy column"
case "$MIG_COLS" in
    *file_published*) green "  ✓ migrated DB has file_published" ;;
    *) red "migrated DB missing file_published: $MIG_COLS"; exit 1 ;;
esac
ANNEXWYRM_DOMAIN="localhost" ANNEXWYRM_BASE_URL="http://localhost" \
ANNEXWYRM_USERNAME="alice" ANNEXWYRM_INSTANCE_NAME="mig e2e" \
ANNEXWYRM_SOCKET="$MIG_SOCK" ANNEXWYRM_DATA="$MIG_DATA" \
ANNEXWYRM_ARCHIVE_REMOTE="$ARCHIVE_REMOTE" \
ANNEXWYRM_PUBLIC_REMOTE="$PUBLIC_REMOTE" \
ANNEXWYRM_PUBLIC_URL_BASE="$PUBLIC_URL_BASE" \
ANNEXWYRM_SERVE_DRAIN=0 \
    "$BINARY" serve > "$MIG_LOG" 2>&1 &
FAIL_PID=$!   # reuse the cleanup-trapped pid slot
wait_for_socket "$MIG_SOCK" 10
login "$MIG_SOCK" "$MIG_JAR" "alice" "$TEST_PASS"
MIG_PATH=$(upload "$MIG_SOCK" "$MIG_JAR" "$PDF_ONE" \
    "Migrated Upload" "" "<p>written through a migrated DB</p>" "1" "")
assert_sql "$MIG_DATA/annexwyrm.db" \
    "SELECT count(*) FROM item WHERE name='Migrated Upload';" \
    "1" "item row EXISTS on the migrated DB (the prod regression)"
assert_status "$MIG_SOCK" "$MIG_PATH" 200
kill "$FAIL_PID" 2>/dev/null || true; wait "$FAIL_PID" 2>/dev/null || true
FAIL_PID=""

green ""
green "=========================================="
green "  e2e (socket) passed.  data dir: $DATA"
green "  daemon log: $LOG"
green "=========================================="
