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

# (d) STORAGE DISCIPLINE — the uploaded bytes must live ONLY in the rclone
#     backend, never on the SERVER's own state/data dir. (The archive remote
#     is the off-box backup; $DATA is the server's local state. On prod the
#     remote is gdrive-crypt — genuinely off-box.) No file under $DATA may
#     equal the uploaded blob, and the blob must be retrievable FROM the
#     backend (proving it is backed up, not lost).
if find "$DATA" -type f -exec cmp -s {} "$PDF_ONE" \; -print 2>/dev/null | grep -q .; then
    red "blob bytes were persisted on the SERVER data dir ($DATA) — must be rclone-only"
    find "$DATA" -type f -exec cmp -s {} "$PDF_ONE" \; -print >&2
    exit 1
fi
green "  ✓ blob NOT persisted under the server data dir (rclone-backend only)"
if [ "$USE_GDRIVE" != "1" ]; then
    cmp -s "$ARCHIVE_REMOTE/$ARCH_SLUG" "$PDF_ONE" \
        && green "  ✓ blob retrievable from the rclone backend (backed up, not on the server)" \
        || { red "blob not retrievable from the rclone backend"; exit 1; }
fi

# (e) PRIVATE = NO LEAK TO ANYONE NOT LOGGED IN — an archived ("private")
#     file must not expose a download link OR url in ANY anon-facing
#     representation: not the HTML page, not the AP JSON a scraper requests.
A_AP=$(fetch_ap_anon "$SOCK" "$ARCH_PATH")
for needle in "uc?export=download" "$ARCHIVE_REMOTE" "$PUBLIC_REMOTE" "drive.google.com"; do
    if printf '%s' "$A_AP" | grep -qF "$needle"; then
        red "archived item's AP JSON leaked a blob reference to anon: $needle"
        printf '%s\n' "$A_AP" >&2
        exit 1
    fi
    if printf '%s' "$A_HTML" | grep -qF "$needle"; then
        red "archived item's HTML leaked a blob reference to anon: $needle"
        exit 1
    fi
done
green "  ✓ archived (private) file leaks no download link/URL to anon (HTML + AP JSON)"
# Federate as a renderable Note (Mastodon shows Note/Article, never Document),
# with the title folded into content, and NO attachment while archived.
assert_grep "$A_AP" '"type":"Note"' "archived item federates as a Note (renderable post)"
assert_grep "$A_AP" "Archived PDF"  "title is folded into the federated content"
if printf '%s' "$A_AP" | grep -qF '"attachment"'; then
    red "archived item federated an attachment (private blob must not federate)"
    exit 1
fi
green "  ✓ archived item carries no federated attachment"

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

# (a+) positive control — a PUBLISHED file SHOULD be reachable by anon (that
#      is the whole point of publishing), including in the AP JSON. This
#      proves the archived-no-leak gate hides only what is private, not
#      everything.
B_AP=$(fetch_ap_anon "$SOCK" "$ARCH_PATH")
if [ "$USE_GDRIVE" = "1" ]; then
    assert_grep "$B_AP" "uc?export=download" "published item's AP JSON exposes the download URL to anon"
else
    assert_grep "$B_AP" "http://example.test/dl/$ARCH_SLUG" "published item's AP JSON exposes the download URL to anon"
fi
# The published file federates as a Document attachment on a Note (so a remote
# Mastodon both renders the post AND shows the downloadable file).
assert_grep "$B_AP" '"type":"Note"'     "published item federates as a Note"
assert_grep "$B_AP" '"type":"Document"' "published file federates as a Document attachment"

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
# The "items" breadcrumb links to /items (and /items/) — both must list the
# archive, not 404.
assert_status "$SOCK" "/items" 200
assert_status "$SOCK" "/items/" 200
assert_grep "$(fetch_html_anon "$SOCK" "/items")" "Archived PDF" "/items lists the archive (no 404)"
HOME_HTML=$(fetch_html_anon "$SOCK" "/")
assert_grep "$HOME_HTML" "Review: praise PDF one"            "review A title on home"
assert_grep "$HOME_HTML" "Review: praise PDF two even more"  "review B title on home"
assert_grep "$HOME_HTML" "Archived PDF"                      "archived item appears on home (no WHERE filter)"
assert_grep "$HOME_HTML" 'rating positive">liked</span>' "rating +2 verb precedes the medium on home"
assert_grep "$HOME_HTML" 'rating positive">a lot</span>' "rating +2 qualifier follows the medium on home"
assert_grep "$HOME_HTML" 'rating positive">loved</span>' "rating +3 verb shown on home (sentence form)"
assert_grep "$HOME_HTML" 'class="rating positive"' "positive-rating css class"
# The published item carries the [file] marker; no privacy word ever appears.
assert_grep "$HOME_HTML" '\[file\]' "published item shows the [file] marker"
if printf '%s' "$HOME_HTML" | grep -qiE 'class="meta">[^<]*· (public|private|unlisted|followers)'; then
    red "home list still renders a privacy word"
    exit 1
fi
green "  ✓ no privacy word on the home list"

note "  review B page contains the hyperlink + rating word + review-of"
REVIEW_B_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_B_PATH")
assert_grep "$REVIEW_B_HTML" "href=\"$TWO_URL\"" "hyperlink to PDF two"
assert_grep "$REVIEW_B_HTML" 'rating positive">loved</span> <em class="medium">' "rating +3 reads 'loved <em>medium</em>' (verb first)"
assert_grep "$REVIEW_B_HTML" "review of"          "review-of badge"

note "  review A page rates +2 and links to PDF one"
REVIEW_A_HTML=$(fetch_html_anon "$SOCK" "$REVIEW_A_PATH")
assert_grep "$REVIEW_A_HTML" 'rating positive">liked</span> <em class="medium">' "rating +2 verb precedes the emphasised medium"
assert_grep "$REVIEW_A_HTML" 'rating positive">a lot</span>' "rating +2 qualifier follows the medium"
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

# ===========================================================================
#  Step G — BINARY round-trip. The first real browser upload (a phone file)
#  failed with "expected multipart/form-data": the C bridge framed the
#  request as METHOD\x1F…\x1FBODY\x1FREMOTE and socket_serve's split("\x1f")
#  silently TRUNCATED the body at its first 0x1F byte (≈1 per 256 bytes of
#  any real JPEG/PDF/audio). Every earlier fixture was ASCII, so 319
#  assertions never noticed. These fixtures contain every byte value
#  0x00–0xFF (0x1F and NUL included) plus multipart boundary-bait, and we
#  assert byte-EXACT round-trips and the exact byte_size/sha256 (codepoint
#  .count on UTF-8-lied bytes undercounts; sha256 catches any mangling).
# ===========================================================================
note "=== Step G — binary upload round-trip (0x1F / NUL / high bytes) ==="

BIN_ONE="$TMP/binary-one.bin"
BIN_TWO="$TMP/binary-two.bin"
python3 - "$BIN_ONE" "$BIN_TWO" <<'PYEOF'
import sys
# Deterministic binary: all 256 byte values, multipart boundary-bait
# (\r\n--, a fake WebKitFormBoundary line), and a keyed byte stretch.
every = bytes(range(256))
bait  = b"\r\n------WebKitFormBoundaryBAIT--\r\n--\x1f\x00\xff"
def blob(key):
    body = every * 8 + bait + bytes((i * 31 + key) % 256 for i in range(4096))
    return body + bait + every
open(sys.argv[1], "wb").write(blob(7))
open(sys.argv[2], "wb").write(blob(131))
PYEOF
BIN_ONE_SIZE=$(wc -c < "$BIN_ONE" | tr -d ' ')
BIN_TWO_SIZE=$(wc -c < "$BIN_TWO" | tr -d ' ')
b64sha() {
    python3 -c "import hashlib,base64,sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1],'rb').read()).digest()).decode())" "$1"
}
BIN_ONE_SHA=$(b64sha "$BIN_ONE")
BIN_TWO_SHA=$(b64sha "$BIN_TWO")
note "binary fixtures: $BIN_ONE_SIZE and $BIN_TWO_SIZE bytes"

# (a) archived binary upload — the exact prod failure shape.
GBIN_PATH=$(upload "$SOCK" "$JAR" "$BIN_ONE" \
    "Binary Archived" "" "<p>binary blob, archived only.</p>" "99" "")
GBIN_URL="http://localhost$GBIN_PATH"
GBIN_SLUG="${GBIN_PATH##*/}"
green "  binary archived item: $GBIN_PATH (slug $GBIN_SLUG)"
assert_status "$SOCK" "$GBIN_PATH" 200
assert_sql "$DB" "SELECT byte_size FROM item WHERE id='$GBIN_URL';" \
    "$BIN_ONE_SIZE" "byte_size is the BYTE count ($BIN_ONE_SIZE), not codepoints"
assert_sql "$DB" "SELECT sha256 FROM item WHERE id='$GBIN_URL';" \
    "$BIN_ONE_SHA" "stored sha256 == sha256 of the original bytes"
assert_log_grep "$LOG" \
    "^\[info\] upload/done id=$GBIN_URL size=$BIN_ONE_SIZE file_published=0\$" \
    "binary archived upload/done with exact byte size"

# (b) published-on-upload binary.
GPUB_PATH=$(upload "$SOCK" "$JAR" "$BIN_TWO" \
    "Binary Published" "" "<p>binary blob, published.</p>" "99" "" "1")
GPUB_URL="http://localhost$GPUB_PATH"
GPUB_SLUG="${GPUB_PATH##*/}"
green "  binary published item: $GPUB_PATH (slug $GPUB_SLUG)"
assert_sql "$DB" "SELECT byte_size FROM item WHERE id='$GPUB_URL';" \
    "$BIN_TWO_SIZE" "published binary byte_size exact"
assert_sql "$DB" "SELECT sha256 FROM item WHERE id='$GPUB_URL';" \
    "$BIN_TWO_SHA" "published binary sha256 exact"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$GPUB_URL';" \
    "1" "published binary file_published=1"

# (c) byte-exact blobs on the local backends (gated exactly like Step A).
if [ "$USE_GDRIVE" = "1" ]; then
    note "  (gdrive) blob byte-compare gated off; sha256 asserts above cover it"
else
    cmp -s "$ARCHIVE_REMOTE/$GBIN_SLUG" "$BIN_ONE" \
        && green "  ✓ archived binary blob byte-identical" \
        || { red "archived binary blob differs from the source"; exit 1; }
    [ ! -e "$PUBLIC_REMOTE/$GBIN_SLUG" ] \
        && green "  ✓ archived binary NOT in the public remote" \
        || { red "archived binary leaked to the public remote"; exit 1; }
    cmp -s "$ARCHIVE_REMOTE/$GPUB_SLUG" "$BIN_TWO" \
        && green "  ✓ published binary archive copy byte-identical" \
        || { red "published binary archive copy differs"; exit 1; }
    cmp -s "$PUBLIC_REMOTE/$GPUB_SLUG" "$BIN_TWO" \
        && green "  ✓ published binary public copy byte-identical" \
        || { red "published binary public copy differs"; exit 1; }
fi

# ===========================================================================
#  Step H — BINARY publish-later. Exercises the OTHER \x1f channel: the
#  spawn result was EXIT\x1fSTDOUT\x1fSTDERR, so blob-get (rclone cat) of a
#  binary blob truncated stdout at its first 0x1F byte and the publish-later
#  copy silently corrupted. Publish Step G's archived binary and assert the
#  public copy is byte-identical to the original.
# ===========================================================================
note "=== Step H — binary publish-later (blob-get path) ==="
H_RESULT=$(post_action "$SOCK" "$JAR" "$GBIN_PATH/publish-file")
H_STATUS="${H_RESULT%%$'\t'*}"
[ "$H_STATUS" = "303" ] || { red "binary publish-file: expected 303, got $H_STATUS"; exit 1; }
green "  ✓ binary publish-file → 303"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$GBIN_URL';" \
    "1" "binary item file_published=1 after publish-later"
if [ "$USE_GDRIVE" = "1" ]; then
    note "  (gdrive) public byte-compare gated off"
else
    cmp -s "$PUBLIC_REMOTE/$GBIN_SLUG" "$BIN_ONE" \
        && green "  ✓ publish-later public copy byte-identical (blob-get survived 0x1F)" \
        || { red "publish-later public copy differs — blob-get mangled the bytes"; exit 1; }
fi

# ===========================================================================
#  Step I — EDIT review metadata. The first real review went up "(untitled)"
#  because the title field arrived empty; there was no way to fix it after
#  upload. Editing changes ONLY the human-authored fields (title, abstract,
#  body, rating, review-of), advances updated_at, federates an Update, and
#  leaves the file blob and its publication state completely untouched.
# ===========================================================================
note "=== Step I — edit review metadata federates an Update ==="
EDIT_PATH=$(upload "$SOCK" "$JAR" "$PDF_TWO" \
    "Pre-edit Title" "" "<p>original body</p>" "99" "")
EDIT_URL="http://localhost$EDIT_PATH"
EDIT_SLUG="${EDIT_PATH##*/}"
green "  item to edit: $EDIT_PATH (slug $EDIT_SLUG)"

# Baseline: a fresh upload has exactly one Create and no Update, and the
# blob's identity (size + hash) is what the edit must preserve.
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$EDIT_URL';" \
    "0" "no Update before the edit"
PRE_SIZE=$(sqlite3 "$DB" "SELECT byte_size FROM item WHERE id='$EDIT_URL';")
PRE_SHA=$(sqlite3 "$DB" "SELECT sha256 FROM item WHERE id='$EDIT_URL';")

# 1s granularity on iso-time: sleep so updated_at strictly advances and the
# >= assertion is meaningful rather than trivially-equal.
sleep 1
E_RESULT=$(edit_item "$SOCK" "$JAR" "$EDIT_SLUG" \
    "Edited Title" "spoilers ahead" \
    "<p>edited body with a <a href=\"https://example.test/x\">link</a></p>" \
    "2" "https://example.test/items/parent")
E_CODE="${E_RESULT%%$'\t'*}"
E_LOC="${E_RESULT#*$'\t'}"
[ "$E_CODE" = "303" ] || { red "edit: expected 303, got $E_CODE"; exit 1; }
green "  ✓ edit → 303"
[ "$E_LOC" = "$EDIT_PATH" ] || { red "edit: expected Location $EDIT_PATH, got $E_LOC"; exit 1; }
green "  ✓ edit Location = $EDIT_PATH"

# (a) DB — every edited field took, updated_at advanced.
assert_sql "$DB" "SELECT name FROM item WHERE id='$EDIT_URL';" \
    "Edited Title" "title updated"
assert_sql "$DB" "SELECT summary FROM item WHERE id='$EDIT_URL';" \
    "spoilers ahead" "summary updated"
assert_sql "$DB" "SELECT rating FROM item WHERE id='$EDIT_URL';" \
    "2" "rating updated (unrated → +2)"
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$EDIT_URL';" \
    "https://example.test/items/parent" "review-of target updated"
assert_sql "$DB" "SELECT (updated_at > published_at) FROM item WHERE id='$EDIT_URL';" \
    "1" "updated_at advanced past published_at"

# (b) the file blob is INVARIANT under a metadata edit.
assert_sql "$DB" "SELECT byte_size FROM item WHERE id='$EDIT_URL';" \
    "$PRE_SIZE" "edit preserves byte_size"
assert_sql "$DB" "SELECT sha256 FROM item WHERE id='$EDIT_URL';" \
    "$PRE_SHA" "edit preserves sha256"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$EDIT_URL';" \
    "0" "edit does NOT publish the archived file"

# (c) federation — exactly one Update, the original Create preserved.
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$EDIT_URL';" \
    "1" "edit emits exactly one Update"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$EDIT_URL';" \
    "1" "the original Create is preserved"
assert_log_grep "$LOG" \
    "^\[info\] item/edited id=$EDIT_URL rating=2\$" \
    "edit logged with the new rating"

# (d) the page reflects the edit to everyone.
E_HTML=$(fetch_html_anon "$SOCK" "$EDIT_PATH")
assert_grep "$E_HTML" "Edited Title"          "edited title renders to anon"
assert_grep "$E_HTML" "edited body with a"    "edited body renders to anon"
assert_grep "$E_HTML" 'review of <a href="https://example.test/items/parent"' \
    "review-of preamble appears after edit"

# (e) the edit link is owner-only.
E_HTML_OWNER=$(fetch_html "$SOCK" "$JAR" "$EDIT_PATH")
assert_grep "$E_HTML_OWNER" "/items/$EDIT_SLUG/edit" "owner sees the edit link"
if printf '%s' "$E_HTML" | grep -q 'class="edit"'; then
    red "anonymous item page leaked an edit link"
    exit 1
fi
green "  ✓ edit link is owner-only"

# ===========================================================================
#  Step J — EDIT owner-gate. An edit with no session must be forbidden and
#  must not mutate the item (the review is read-only to everyone but its
#  single local owner).
# ===========================================================================
note "=== Step J — edit owner-gate (anonymous edit forbidden) ==="
J_CODE=$(edit_item_anon "$SOCK" "$EDIT_SLUG")
[ "$J_CODE" = "403" ] || { red "anonymous edit: expected 403, got $J_CODE"; exit 1; }
green "  ✓ anonymous edit → 403"
assert_sql "$DB" "SELECT name FROM item WHERE id='$EDIT_URL';" \
    "Edited Title" "anonymous edit changed nothing"

# ===========================================================================
#  Step K — EDIT a REVIEW. A "review" is just an item whose in_reply_to is
#  non-empty (annex-item/is-review). The first real post on prod was exactly
#  this shape — a Cube Cobra review that went up "(untitled)". This step
#  uploads an item that is ALREADY a review at creation, then edits its
#  title/body/rating AND retargets its review-of, proving reviews are
#  first-class editable (not only plain items that get a review-of added).
# ===========================================================================
note "=== Step K — edit a review (item with in_reply_to) ==="
REV_PARENT="https://cubecobra.com/cube/about/kamigawa_block_revisited"
REV_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" \
    "" "" "<p>original review body</p>" "1" "$REV_PARENT")
REV_URL="http://localhost$REV_PATH"
REV_SLUG="${REV_PATH##*/}"
green "  review to edit: $REV_PATH (slug $REV_SLUG)"

# It is a review from the start: in_reply_to set, and the page shows the
# "review of" preamble even while still "(untitled)".
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$REV_URL';" \
    "$REV_PARENT" "uploaded item IS a review (in_reply_to set)"
K_PRE_HTML=$(fetch_html_anon "$SOCK" "$REV_PATH")
assert_grep "$K_PRE_HTML" "(untitled)" "review starts untitled (the prod symptom)"
assert_grep "$K_PRE_HTML" "review of <a href=\"$REV_PARENT\"" "review-of preamble present pre-edit"

# FEDERATION: a review is a standalone Note that REFERENCES the reviewed URL
# in its content — NOT an AP reply. Setting inReplyTo to a non-fediverse URL
# makes Mastodon flag the status as a reply with an unresolvable parent and
# hides it from the profile's "Posts" tab. So the federated Note must carry
# NO inReplyTo, and fold "review of <link>" into the content instead.
REV_AP=$(fetch_ap_anon "$SOCK" "$REV_PATH")
assert_grep "$REV_AP" '"type":"Note"' "review federates as a Note"
assert_grep "$REV_AP" "review of <a href" "review-of preamble folded into federated content"
assert_grep "$REV_AP" "$REV_PARENT"       "reviewed URL present in the federated content"
if printf '%s' "$REV_AP" | grep -qF '"inReplyTo"'; then
    red "review federated WITH inReplyTo — Mastodon would hide it from the Posts tab"
    exit 1
fi
green "  ✓ review federates as a top-level Note (no inReplyTo)"

sleep 1
K_RESULT=$(edit_item "$SOCK" "$JAR" "$REV_SLUG" \
    "Six's Sharpied Kamigawa" "" \
    "<p>Amazing explainer of game design and a feat of design any magic player dreams of.</p>" \
    "2" "$REV_PARENT")
K_CODE="${K_RESULT%%$'\t'*}"
[ "$K_CODE" = "303" ] || { red "review edit: expected 303, got $K_CODE"; exit 1; }
green "  ✓ review edit → 303"

# (a) the review is no longer untitled, body+rating updated, STILL a review.
assert_sql "$DB" "SELECT name FROM item WHERE id='$REV_URL';" \
    "Six's Sharpied Kamigawa" "review title set (no longer untitled)"
assert_sql "$DB" "SELECT rating FROM item WHERE id='$REV_URL';" \
    "2" "review rating updated (+1 → +2)"
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$REV_URL';" \
    "$REV_PARENT" "review-of target preserved through the edit"

# (b) it federates an Update (a review edit is an Update, like any item).
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$REV_URL';" \
    "1" "review edit emits exactly one Update"

# (c) the page now shows the real title AND keeps the review-of preamble.
K_HTML=$(fetch_html_anon "$SOCK" "$REV_PATH")
assert_grep "$K_HTML" "Six&#39;s Sharpied Kamigawa" "edited review title renders (apostrophe escaped)"
assert_grep "$K_HTML" "review of <a href=\"$REV_PARENT\"" "review-of preamble survives the edit"
# rating is shown in plain WORDS only — no stars, no numeric score.
assert_grep "$K_HTML" 'rating positive">liked</span> <em class="medium">' "rating +2 sentence (verb first, medium emphasised)"
if printf '%s' "$K_HTML" | grep -qE '★|☆|of ±3'; then
    red "rating still renders stars or a numeric score"; exit 1; fi
green "  ✓ rating is words only (no stars, no score)"
if printf '%s' "$K_HTML" | grep -q '(untitled)'; then
    red "review still shows (untitled) after the edit"
    exit 1
fi
green "  ✓ review no longer untitled"

# (d) retarget the review-of to a different parent — editing the review
#     relationship itself works.
sleep 1
REV_PARENT2="https://cubecobra.com/cube/about/some_other_cube"
K2_RESULT=$(edit_item "$SOCK" "$JAR" "$REV_SLUG" \
    "Six's Sharpied Kamigawa" "" \
    "<p>Amazing explainer of game design and a feat of design any magic player dreams of.</p>" \
    "2" "$REV_PARENT2")
K2_CODE="${K2_RESULT%%$'\t'*}"
[ "$K2_CODE" = "303" ] || { red "review retarget: expected 303, got $K2_CODE"; exit 1; }
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$REV_URL';" \
    "$REV_PARENT2" "review-of retargeted to a new parent"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$REV_URL';" \
    "2" "the retarget emits a second Update"
green "  ✓ review-of is itself editable"

# ===========================================================================
#  Step L — EDIT round-trips through multipart + the DB framing. The edit form
#  is now multipart/form-data (it can carry a file), so field values ride the
#  wire VERBATIM (no url-encoding). This guards:
#    (a) multibyte UTF-8 (accents/emoji) survives multipart byte-exact,
#    (b) literal spaces + apostrophe + HTML survive (no mangling),
#    (c) a 'review of' URL with a query string survives whole,
#    (d) framing-significant control bytes (TAB/0x1E/0x1F) survive the request
#        framing AND the DB param framing byte-exact.
#  The url-decode edge cases (+ / %27 / first-'=') move to Step L2 (search),
#  which still routes through query-parse/url-decode.
# ===========================================================================
note "=== Step L — edit round-trips (UTF-8 / literals / control bytes via multipart) ==="
ENC_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" "enc seed" "" "<p>seed</p>" "99" "")
ENC_URL="http://localhost$ENC_PATH"
ENC_SLUG="${ENC_PATH##*/}"

# (a) UTF-8 title with accents, an em dash, an apostrophe, stars and an emoji —
#     --form-string sends the raw UTF-8 bytes; multipart must preserve them.
UTITLE="Café déjà — Six's ★★ 🎴"
edit_item "$SOCK" "$JAR" "$ENC_SLUG" "$UTITLE" "" "<p>seed</p>" "2" "" >/dev/null
assert_sql "$DB" "SELECT name FROM item WHERE id='$ENC_URL';" \
    "$UTITLE" "UTF-8 title round-trips byte-exact (no mojibake)"
ENC_HTML=$(fetch_html_anon "$SOCK" "$ENC_PATH")
assert_grep "$ENC_HTML" "Café déjà" "accented title renders on the page"
assert_grep "$ENC_HTML" "🎴" "emoji in the title renders on the page"

# (b) literal spaces, apostrophe, and HTML in the title/content survive
#     multipart verbatim (no '+'/escape interpretation in a multipart part).
edit_item "$SOCK" "$JAR" "$ENC_SLUG" "Six's Sharpied Kamigawa" "" "<p>x</p>" "2" "" >/dev/null
assert_sql "$DB" "SELECT name FROM item WHERE id='$ENC_URL';" \
    "Six's Sharpied Kamigawa" "literal title (spaces + apostrophe) round-trips"
assert_sql "$DB" "SELECT content FROM item WHERE id='$ENC_URL';" \
    "<p>x</p>" "literal HTML content round-trips"

# (c) a review-of URL carrying a query string must survive whole.
QURL="https://cubecobra.com/cube/list/abc?view=table&sort=cmc"
edit_item "$SOCK" "$JAR" "$ENC_SLUG" "$UTITLE" "" "<p>seed</p>" "2" "$QURL" >/dev/null
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$ENC_URL';" \
    "$QURL" "review-of URL with query '=' survives whole"

# (d) DB param/result FRAMING: a stored text value containing the framing-
#     significant control bytes (TAB 0x09, 0x1E, 0x1F) must round-trip
#     byte-exact through the request framing (socket_server split-limit, body
#     is the last field) AND the param encode → C bind → SQLite → C query →
#     parse-cell. Sent as LITERAL bytes in the multipart part — strictly
#     stronger than the old percent-encoded form. Read back as hex.
CTRL_CONTENT=$(printf 'A\tB\x1eC\x1fD-end')   # A<TAB>B<0x1E>C<0x1F>D-end
edit_item "$SOCK" "$JAR" "$ENC_SLUG" "ctl" "" "$CTRL_CONTENT" "2" "" >/dev/null
GOT_HEX=$(sqlite3 "$DB" "SELECT hex(content) FROM item WHERE id='$ENC_URL';")
WANT_HEX="4109421E431F442D656E64"   # "A\tB\x1eC\x1fD-end"
[ "$GOT_HEX" = "$WANT_HEX" ] \
    && green "  ✓ control bytes (TAB/0x1E/0x1F) round-trip byte-exact through request + DB framing" \
    || { red "framing corrupted control bytes: got $GOT_HEX want $WANT_HEX"; exit 1; }

# ===========================================================================
#  Step L2 — query-parse / url-decode edge cases via SEARCH (the path that
#  still url-decodes a query string): multibyte UTF-8, '+'-as-space, and a
#  %27 apostrophe. The search page echoes the decoded query in its heading +
#  box, so a correct decode is visible in the rendered HTML.
# ===========================================================================
note "=== Step L2 — url-decode edge cases via /search?q= ==="
# UTF-8 (%C3%A9 is ONE codepoint 'é', not two) + '+'→space.
SQ_HTML=$(fetch_html_anon "$SOCK" "/search?q=Caf%C3%A9+d%C3%A9j%C3%A0")
assert_grep "$SQ_HTML" "Café déjà" "search decodes UTF-8 and '+'→space (no mojibake)"
# %27 → apostrophe, HTML-escaped on render.
SQ_HTML2=$(fetch_html_anon "$SOCK" "/search?q=Six%27s")
assert_grep "$SQ_HTML2" "Six&#39;s" "search decodes %27 → apostrophe (then HTML-escaped)"

# ===========================================================================
#  Step M — edit a PUBLISHED review. The first real prod review is published
#  (a download link is live), and editing it must keep the file published
#  with its minted URL intact — a text edit never retracts the download.
#  ARCH (Steps A/B) is exactly that: published with a public URL.
# ===========================================================================
note "=== Step M — edit a published review keeps its download link ==="
M_PRE_URL=$(sqlite3 "$DB" "SELECT file_public_url FROM item WHERE id='$ARCH_URL';")
[ -n "$M_PRE_URL" ] || { red "precondition: ARCH item should have a public URL by now"; exit 1; }
sleep 1
# The edit form's publish_file checkbox is pre-checked for a published item, so
# a browser edit submits publish_file=1 → the file stays published. We pass the
# "publish" flag to simulate that pre-checked state (omitting it would, by
# design, un-publish — the checkbox is the authoritative desired state).
edit_item "$SOCK" "$JAR" "$ARCH_SLUG" \
    "Published And Edited" "" "<p>edited published body</p>" "3" "" "" "" "publish" >/dev/null
assert_sql "$DB" "SELECT name FROM item WHERE id='$ARCH_URL';" \
    "Published And Edited" "published item's title edited"
assert_sql "$DB" "SELECT rating FROM item WHERE id='$ARCH_URL';" \
    "3" "published item's rating edited"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$ARCH_URL';" \
    "1" "edit KEEPS the file published"
assert_sql "$DB" "SELECT file_public_url FROM item WHERE id='$ARCH_URL';" \
    "$M_PRE_URL" "edit preserves the minted download URL"
M_HTML=$(fetch_html_anon "$SOCK" "$ARCH_PATH")
assert_grep "$M_HTML" 'class="download"'  "published+edited page still shows the download link"
assert_grep "$M_HTML" "Published And Edited" "published+edited title renders"
assert_grep "$M_HTML" 'rating positive">loved</span> <em class="medium">' "rating +3 sentence on the item page"
# the home list also describes ratings in words, not bare stars.
M_HOME=$(fetch_html_anon "$SOCK" "/")
assert_grep "$M_HOME" 'rating positive">loved</span>' "home list shows the rating sentence verb"

# ===========================================================================
#  Step N — TAGS + SEARCH. Upload with tags; assert normalisation, the item
#  page chips, AP Hashtag federation, the /tags/<tag> + /tags index + /search
#  listings, and that an edit replaces the tag set.
# ===========================================================================
note "=== Step N — tags + search ==="
TAG_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" \
    "Tagged Review" "" "<p>about kamigawa limited</p>" "2" "" "" "MTG, #Kamigawa limited")
TAG_URL="http://localhost$TAG_PATH"
TAG_SLUG="${TAG_PATH##*/}"
green "  tagged item: $TAG_PATH"

# (a) tags stored NORMALISED (lowercase, no '#') and de-duped.
assert_sql "$DB" \
    "SELECT group_concat(tag, ',') FROM (SELECT tag FROM item_tag WHERE item_id='$TAG_URL' ORDER BY tag);" \
    "kamigawa,limited,mtg" "tags stored normalised (lowercased, no '#'), sorted"

# (b) the item page shows clickable tag chips.
TAG_HTML=$(fetch_html_anon "$SOCK" "$TAG_PATH")
assert_grep "$TAG_HTML" 'href="/tags/kamigawa"' "item page renders the #kamigawa chip"
assert_grep "$TAG_HTML" 'href="/tags/mtg"'      "item page renders the #mtg chip"

# (c) tags federate as AP Hashtag entries in the object's tag[] and in the
#     stored Create activity.
TAG_AP=$(fetch_ap_anon "$SOCK" "$TAG_PATH")
assert_grep "$TAG_AP" '"type":"Hashtag"' "AP object federates Hashtag tags"
assert_grep "$TAG_AP" '"name":"#kamigawa"' "AP Hashtag name is #kamigawa"
assert_sql "$DB" "SELECT (raw LIKE '%Hashtag%') FROM activity WHERE type='Create' AND object_id='$TAG_URL';" \
    "1" "the federated Create carries the Hashtag tag"

# (d) /tags/<tag> lists the item; the segment is normalised (/tags/MTG → mtg).
assert_grep "$(fetch_html_anon "$SOCK" "/tags/kamigawa")" "Tagged Review" \
    "/tags/kamigawa lists the item"
assert_grep "$(fetch_html_anon "$SOCK" "/tags/MTG")" "Tagged Review" \
    "/tags/MTG normalises to mtg and lists the item"

# (e) search matches by title, by tag/content, and reports no-match cleanly.
assert_grep "$(fetch_html_anon "$SOCK" "/search?q=Tagged")" "Tagged Review" \
    "search matches the title"
assert_grep "$(fetch_html_anon "$SOCK" "/search?q=kamigawa")" "Tagged Review" \
    "search matches a tag / the content"
assert_grep "$(fetch_html_anon "$SOCK" "/search?q=zzpdqnonexistent")" "no matches" \
    "search with no results shows the empty message"

# (f) the /tags index lists the tag.
assert_grep "$(fetch_html_anon "$SOCK" "/tags")" 'href="/tags/kamigawa"' \
    "the /tags index lists kamigawa"

# (g) editing replaces the whole tag set.
edit_item "$SOCK" "$JAR" "$TAG_SLUG" \
    "Tagged Review" "" "<p>now about something else</p>" "2" "" "draft solo" >/dev/null
assert_sql "$DB" \
    "SELECT group_concat(tag, ',') FROM (SELECT tag FROM item_tag WHERE item_id='$TAG_URL' ORDER BY tag);" \
    "draft,solo" "edit replaces the tag set"
if printf '%s' "$(fetch_html_anon "$SOCK" "/tags/kamigawa")" | grep -q "Tagged Review"; then
    red "after the edit, the removed #kamigawa tag still lists the item"
    exit 1
fi
green "  ✓ an edited-away tag no longer lists the item"

# (h) tag normalisation restricts the charset to URL-/HTML-safe word chars:
#     a tag with a slash or HTML metacharacters is sanitised, never stored or
#     rendered raw — so it can't federate a dead href, 404 its own listing, or
#     inject markup. (Security-review regression.)
XPATH=$(upload "$SOCK" "$JAR" "$PDF_TWO" "Tag charset probe" "" "<p>x</p>" "99" "" "" "rpg/2024 c++ safe <b>x</b>")
XURL="http://localhost$XPATH"
# rpg/2024 → rpg2024 ; c++ → c ; "<b>x</b>" → bxb ; safe → safe (sorted)
assert_sql "$DB" \
    "SELECT group_concat(tag, ',') FROM (SELECT tag FROM item_tag WHERE item_id='$XURL' ORDER BY tag);" \
    "bxb,c,rpg2024,safe" "tags restricted to URL/HTML-safe word chars (no '/','+','<','>')"
XHTML=$(fetch_html_anon "$SOCK" "$XPATH")
if printf '%s' "$XHTML" | grep -q '<b>x</b>'; then
    red "a tag injected raw HTML into the item page"
    exit 1
fi
green "  ✓ tag with HTML metacharacters is sanitised on render"
# the sanitised single-segment tag routes cleanly (no slash → no 404).
assert_grep "$(fetch_html_anon "$SOCK" "/tags/rpg2024")" "Tag charset probe" \
    "sanitised tag (rpg/2024 → rpg2024) routes to a valid /tags listing"
# the federated Hashtag href is a single clean path segment (no slash after /tags/).
XAP=$(fetch_ap_anon "$SOCK" "$XPATH")
assert_grep "$XAP" '/tags/rpg2024' "federated Hashtag href is a clean single segment"

# ===========================================================================
#  Step O — MARKDOWN rendering + the content-warning SPOILER actually hiding
#  the body. The review body is Markdown (safe: HTML-escaped, fixed tag
#  allow-list, scheme-restricted links). With a CW set, the body must be
#  wrapped in <details> so it is hidden until clicked.
# ===========================================================================
note "=== Step O — markdown rendering + spoiler ==="
MD=$(cat <<'MDEOF'
## Sub heading

This is **bold** and *italic* and a [link](https://example.com) and `inline code`.

- first
- second

A <script>alert(1)</script> tag and a [bad](javascript:alert(1)) link.

Triple ***emph*** and a [rel](//evil.example/phish) protocol-relative link.
MDEOF
)
MD_PATH=$(upload "$SOCK" "$JAR" "$PDF_ONE" "Markdown test" "spoilers ahead" "$MD" "99" "")
MD_HTML=$(fetch_html_anon "$SOCK" "$MD_PATH")
assert_grep "$MD_HTML" "<h2>Sub heading</h2>"            "markdown heading → <h2>"
assert_grep "$MD_HTML" "<strong>bold</strong>"           "markdown **bold**"
assert_grep "$MD_HTML" "<em>italic</em>"                  "markdown *italic*"
assert_grep "$MD_HTML" '<a href="https://example.com" rel="nofollow">link</a>' "markdown [link](url)"
assert_grep "$MD_HTML" "<code>inline code</code>"         "markdown \`code\`"
assert_grep "$MD_HTML" "<li>first</li>"                   "markdown - list item"
# XSS: raw HTML in the body must be escaped, never emitted.
if printf '%s' "$MD_HTML" | grep -qF '<script>alert(1)</script>'; then
    red "raw <script> survived markdown rendering"; exit 1; fi
assert_grep "$MD_HTML" "&lt;script&gt;" "raw HTML in the body is escaped"
# A non-safe link scheme must NOT become an <a href>.
if printf '%s' "$MD_HTML" | grep -qF 'href="javascript:'; then
    red "javascript: link was rendered as an anchor"; exit 1; fi
green "  ✓ markdown is XSS-safe (no raw HTML, no javascript: anchors)"
# Triple emphasis ***x*** → bold-italic.
assert_grep "$MD_HTML" "<strong><em>emph</em></strong>" "triple emphasis → <strong><em>"
# Protocol-relative //host must NOT become a link (off-site navigation).
if printf '%s' "$MD_HTML" | grep -qF 'href="//evil.example'; then
    red "protocol-relative // URL rendered as a live link"; exit 1; fi
green "  ✓ protocol-relative // link is not rendered as an anchor"
# A javascript: in_reply_to must render as escaped text, not a clickable href
# (HTML-escaping alone leaves a live javascript: anchor).
JS_PATH=$(upload "$SOCK" "$JAR" "$PDF_TWO" "js reviewof probe" "" "<p>x</p>" "99" "javascript:alert(2)")
JS_HTML=$(fetch_html_anon "$SOCK" "$JS_PATH")
if printf '%s' "$JS_HTML" | grep -qF 'href="javascript:'; then
    red "javascript: in_reply_to rendered as a clickable anchor (XSS)"; exit 1; fi
green "  ✓ javascript: review-of URL renders as text, not an anchor"

# ===========================================================================
#  Step P — FILE-LESS review. A review can reference a resource (a book URL)
#  with NO uploaded file: no blob, no remotes, byte_size 0, a Note that
#  federates and shows no file-state line. (Needed for the bookwyrm import.)
# ===========================================================================
note "=== Step P — file-less (text-only) review ==="
PTXT_HDR=$(mktemp)
curl -s -o /dev/null -D "$PTXT_HDR" --unix-socket "$SOCK" --cookie "$JAR" \
  --form-string "name=Snow Crash" --form-string "summary=" \
  --form-string "content=A **great** read." \
  --form-string "rating=2" \
  --form-string "in_reply_to=https://bookwyrm.social/book/1000" \
  --form-string "tags=scifi" \
  "http://x/upload"
PTXT_PATH=$(grep -i '^location:' "$PTXT_HDR" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r'); rm -f "$PTXT_HDR"
[ -n "$PTXT_PATH" ] || { red "file-less upload returned no Location"; exit 1; }
PTXT_URL="http://localhost$PTXT_PATH"
assert_sql "$DB" "SELECT byte_size FROM item WHERE id='$PTXT_URL';" "0" "file-less review byte_size 0"
assert_sql "$DB" "SELECT count(*) FROM item_remote WHERE item_id='$PTXT_URL';" "0" "file-less review has no mirror remotes"
assert_sql "$DB" "SELECT object_type FROM item WHERE id='$PTXT_URL';" "Note" "file-less review is a Note"
assert_sql "$DB" "SELECT in_reply_to FROM item WHERE id='$PTXT_URL';" "https://bookwyrm.social/book/1000" "review-of book URL stored"
PTXT_HTML=$(fetch_html_anon "$SOCK" "$PTXT_PATH")
assert_grep "$PTXT_HTML" "<strong>great</strong>" "file-less review renders markdown"
assert_grep "$PTXT_HTML" 'review of <a href="https://bookwyrm.social/book/1000"' "review-of link to the book"
if printf '%s' "$PTXT_HTML" | grep -q "file archived, not published"; then
    red "file-less review wrongly shows a file-state line"; exit 1; fi
green "  ✓ file-less review shows no file-state"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$PTXT_URL';" "1" "file-less review federates a Create"
# SPOILER: with a CW set, the body is wrapped in <details> (hidden) — and the
# content section lives INSIDE the details, not outside it.
assert_grep "$MD_HTML" '<details class="cw"><summary>spoilers ahead</summary>' \
    "content warning wraps the body in a spoiler"
AFTER_DETAILS="${MD_HTML#*<details class=\"cw\">}"
BEFORE_DETAILS="${MD_HTML%%<details class=\"cw\">*}"
printf '%s' "$AFTER_DETAILS" | grep -q '<section class="content">' \
    && green "  ✓ the body is INSIDE the spoiler (hidden until clicked)" \
    || { red "body content is not inside the spoiler details"; exit 1; }
if printf '%s' "$BEFORE_DETAILS" | grep -q '<section class="content">'; then
    red "body content also renders OUTSIDE the spoiler (not hidden)"; exit 1; fi

# ===========================================================================
#  Step R — FILE LIFECYCLE FROM THE EDIT FORM. The edit page manages the blob
#  too: attach a file to a file-less review (archived), publish it, then make
#  it private again. Every transition holds the security invariants — the blob
#  lives only in rclone (never $DATA), an archived/retracted file leaks no
#  download to anon (HTML + AP), and un-publishing DELETES the public copy
#  (revokes access, not just hides the link).
# ===========================================================================
note "=== Step R — manage the file from the edit form ==="
# A file-less review to attach a file to.
RF_HDR=$(mktemp)
curl -s -o /dev/null -D "$RF_HDR" --unix-socket "$SOCK" --cookie "$JAR" \
  --form-string "name=Little Fires" --form-string "summary=" \
  --form-string "content=A review that will gain a file." \
  --form-string "rating=1" --form-string "in_reply_to=https://bookwyrm.social/book/2000" \
  "http://x/upload"
RF_PATH=$(grep -i '^location:' "$RF_HDR" | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '\r'); rm -f "$RF_HDR"
RF_URL="http://localhost$RF_PATH"; RF_SLUG="${RF_PATH##*/}"
green "  file-less review: $RF_PATH (slug $RF_SLUG)"
assert_sql "$DB" "SELECT byte_size FROM item WHERE id='$RF_URL';" "0" "starts file-less"
UPD0=$(sqlite3 "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$RF_URL';")

# --- R1: attach a PRIVATE file via edit (file part, no publish) ---
R1=$(edit_item "$SOCK" "$JAR" "$RF_SLUG" "Little Fires" "" \
     "A review that will gain a file." "1" "https://bookwyrm.social/book/2000" "" "$PDF_ONE")
[ "${R1%%$'\t'*}" = "303" ] || { red "R1 attach: expected 303, got ${R1%%$'\t'*}"; exit 1; }
green "  ✓ R1 attach-private → 303"
assert_sql "$DB" "SELECT (byte_size>0) FROM item WHERE id='$RF_URL';" "1" "R1: file now has bytes"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$RF_URL';" "0" "R1: file archived (not published)"
assert_sql "$DB" "SELECT (file_public_url IS NULL OR file_public_url='') FROM item WHERE id='$RF_URL';" "1" "R1: no public URL"
assert_sql "$DB" "SELECT count(*) FROM item_remote WHERE item_id='$RF_URL';" "1" "R1: only the archive remote"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$RF_URL';" "$((UPD0+1))" "R1: one Update federated"
if [ "$USE_GDRIVE" != "1" ]; then
    [ -f "$ARCHIVE_REMOTE/$RF_SLUG" ] || { red "R1: archive blob missing"; exit 1; }
    cmp -s "$ARCHIVE_REMOTE/$RF_SLUG" "$PDF_ONE" || { red "R1: archive blob bytes differ"; exit 1; }
    green "  ✓ R1: archived blob present in rclone backend == plaintext"
    [ -f "$PUBLIC_REMOTE/$RF_SLUG" ] && { red "R1: public remote has the blob (must be archived only)"; exit 1; }
    green "  ✓ R1: public remote does NOT have the blob"
fi
if find "$DATA" -type f -exec cmp -s {} "$PDF_ONE" \; -print 2>/dev/null | grep -q .; then
    red "R1: blob persisted on server data dir — must be rclone-only"; exit 1; fi
green "  ✓ R1: blob not on server data dir"
R1_HTML=$(fetch_html_anon "$SOCK" "$RF_PATH")
assert_grep "$R1_HTML" "file archived, not published" "R1: archived file-state line to anon"
if printf '%s' "$R1_HTML" | grep -q 'class="download"'; then red "R1: archived page leaked a download anchor"; exit 1; fi
green "  ✓ R1: no download anchor for the archived file"
R1_AP=$(fetch_ap_anon "$SOCK" "$RF_PATH")
if printf '%s' "$R1_AP" | grep -qF '"attachment"'; then red "R1: archived item federated an attachment"; exit 1; fi
green "  ✓ R1: archived item federates no attachment"

# --- R1b: the OWNER (signed in) CAN privately download the archived file via
#          the authenticated /items/<id>/file route; an anon CANNOT. The blob
#          is streamed from the encrypted archive — it never gets a public URL.
OWN_CODE=$(curl -s -o "$TMP/r1b.own.dl" -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" "http://x$RF_PATH/file")
[ "$OWN_CODE" = "200" ] || { red "R1b: owner private download expected 200, got $OWN_CODE"; exit 1; }
cmp -s "$TMP/r1b.own.dl" "$PDF_ONE" || { red "R1b: owner-downloaded archived bytes != original"; exit 1; }
green "  ✓ R1b: owner privately downloads the archived file (200, bytes == original)"
ANON_DL_CODE=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "http://x$RF_PATH/file")
[ "$ANON_DL_CODE" = "403" ] || { red "R1b: anon private download expected 403, got $ANON_DL_CODE"; exit 1; }
green "  ✓ R1b: anon is FORBIDDEN from the private download (403, no bytes)"
# the page: owner sees the private download link; anon does NOT.
R1_OWNER_HTML=$(fetch_html "$SOCK" "$JAR" "$RF_PATH")
assert_grep "$R1_OWNER_HTML" "/items/$RF_SLUG/file" "R1b: owner sees the private download link"
if printf '%s' "$R1_HTML" | grep -q "/items/$RF_SLUG/file"; then
    red "R1b: anon page leaked the private download link"; exit 1; fi
green "  ✓ R1b: anon page does NOT show the private download link"

# --- R2: PUBLISH the file via edit (publish checkbox, no new file) ---
R2=$(edit_item "$SOCK" "$JAR" "$RF_SLUG" "Little Fires" "" \
     "A review that will gain a file." "1" "https://bookwyrm.social/book/2000" "" "" "publish")
[ "${R2%%$'\t'*}" = "303" ] || { red "R2 publish: expected 303, got ${R2%%$'\t'*}"; exit 1; }
green "  ✓ R2 publish → 303"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$RF_URL';" "1" "R2: file is published"
assert_sql "$DB" "SELECT (file_public_url IS NOT NULL AND file_public_url != '') FROM item WHERE id='$RF_URL';" "1" "R2: public URL minted"
assert_sql "$DB" "SELECT count(*) FROM item_remote WHERE item_id='$RF_URL';" "2" "R2: archive + public remotes"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$RF_URL';" "$((UPD0+2))" "R2: second Update federated"
# PROVE the published object is actually SERVABLE from the public remote the
# same way prod serves it — through rclone (the exact tool that talks to Google
# Drive in production), not a filesystem stat. These checks run for BOTH the
# local-temp backend AND a real `gdrive:` remote (ANNEXWYRM_E2E_GDRIVE=1), so on
# the gdrive suite this exercises Google Drive itself.
rclone cat "$PUBLIC_REMOTE/$RF_SLUG" > "$TMP/r2.dl" 2>/dev/null \
    || { red "R2: rclone cannot fetch the published blob from the public remote"; exit 1; }
cmp -s "$TMP/r2.dl" "$PDF_ONE" || { red "R2: fetched public blob bytes != original"; exit 1; }
green "  ✓ R2: published blob is fetchable from the public remote (rclone) and == original"
rclone lsf "$PUBLIC_REMOTE" 2>/dev/null | grep -qx "$RF_SLUG" \
    || { red "R2: public remote does not list the published blob"; exit 1; }
green "  ✓ R2: public remote lists the published object"
R2_HTML=$(fetch_html_anon "$SOCK" "$RF_PATH")
assert_grep "$R2_HTML" 'class="download"' "R2: download anchor now shown to anon"
R2_AP=$(fetch_ap_anon "$SOCK" "$RF_PATH")
assert_grep "$R2_AP" '"type":"Document"' "R2: published file federates as a Document attachment"

# --- R3: make it PRIVATE again via edit (uncheck publish, no new file) ---
R3=$(edit_item "$SOCK" "$JAR" "$RF_SLUG" "Little Fires" "" \
     "A review that will gain a file." "1" "https://bookwyrm.social/book/2000" "")
[ "${R3%%$'\t'*}" = "303" ] || { red "R3 unpublish: expected 303, got ${R3%%$'\t'*}"; exit 1; }
green "  ✓ R3 make-private → 303"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$RF_URL';" "0" "R3: file archived again"
assert_sql "$DB" "SELECT (file_public_url IS NULL OR file_public_url='') FROM item WHERE id='$RF_URL';" "1" "R3: public URL cleared"
assert_sql "$DB" "SELECT count(*) FROM item_remote WHERE item_id='$RF_URL';" "1" "R3: public mirror dropped (archive only)"
assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Update' AND object_id='$RF_URL';" "$((UPD0+3))" "R3: third Update federated"
# ★ THE INVARIANT THAT MATTERS MOST ★ — making a file private must ERASE it from
# the public backend, not merely hide the link. Prove it the way a downloader
# (or Google Drive) sees it: the object is no longer fetchable AND no longer
# listed via rclone. (blob-del runs `rclone deletefile --drive-use-trash=false`,
# so on Drive it is permanently deleted — no recoverable Trash, dead share link.)
if rclone cat "$PUBLIC_REMOTE/$RF_SLUG" >/dev/null 2>&1; then
    red "R3: public object STILL FETCHABLE via rclone after make-private — NOT revoked"; exit 1; fi
green "  ✓ R3: public object no longer fetchable from the backend (download path is dead)"
if rclone lsf "$PUBLIC_REMOTE" 2>/dev/null | grep -qx "$RF_SLUG"; then
    red "R3: public remote still lists the object after make-private"; exit 1; fi
green "  ✓ R3: public remote no longer lists the object (erased, not hidden)"
# …but the ENCRYPTED ARCHIVE copy must survive byte-identical — data is never
# lost, only the public exposure is revoked.
rclone cat "$ARCHIVE_REMOTE/$RF_SLUG" > "$TMP/r3.arch" 2>/dev/null \
    || { red "R3: archive blob unfetchable — must always survive"; exit 1; }
cmp -s "$TMP/r3.arch" "$PDF_ONE" || { red "R3: archive blob changed/corrupted on make-private"; exit 1; }
green "  ✓ R3: encrypted archive copy survives byte-identical (data retained, exposure revoked)"
R3_HTML=$(fetch_html_anon "$SOCK" "$RF_PATH")
if printf '%s' "$R3_HTML" | grep -q 'class="download"'; then red "R3: still shows a download anchor after make-private"; exit 1; fi
green "  ✓ R3: download anchor gone from the page"
R3_AP=$(fetch_ap_anon "$SOCK" "$RF_PATH")
if printf '%s' "$R3_AP" | grep -qF '"attachment"'; then red "R3: still federates an attachment after make-private"; exit 1; fi
for needle in "uc?export=download" "$PUBLIC_REMOTE" "drive.google.com"; do
    if printf '%s' "$R3_AP" | grep -qF "$needle"; then red "R3: AP JSON still leaks a public-blob reference: $needle"; exit 1; fi
done
green "  ✓ R3: attachment + all public-blob references retracted from federation"
# Make-private revokes PUBLIC access but the OWNER keeps private access — the
# archive copy is intact, so the authenticated download still works.
R3_OWN_CODE=$(curl -s -o "$TMP/r3.own.dl" -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" "http://x$RF_PATH/file")
{ [ "$R3_OWN_CODE" = "200" ] && cmp -s "$TMP/r3.own.dl" "$PDF_ONE"; } \
    && green "  ✓ R3: owner still privately downloads the file (public revoked, owner access intact)" \
    || { red "R3: owner lost private access after make-private (code=$R3_OWN_CODE)"; exit 1; }

# --- R4: re-publish after private. The object must come BACK and be fetchable
#         again — proving R3 genuinely DELETED it (re-publish had to re-create
#         it), and that the public↔private cycle is repeatable. ---
R4=$(edit_item "$SOCK" "$JAR" "$RF_SLUG" "Little Fires" "" \
     "A review that will gain a file." "1" "https://bookwyrm.social/book/2000" "" "" "publish")
[ "${R4%%$'\t'*}" = "303" ] || { red "R4 re-publish: expected 303, got ${R4%%$'\t'*}"; exit 1; }
green "  ✓ R4 re-publish → 303"
assert_sql "$DB" "SELECT file_published FROM item WHERE id='$RF_URL';" "1" "R4: file is published again"
rclone cat "$PUBLIC_REMOTE/$RF_SLUG" > "$TMP/r4.dl" 2>/dev/null \
    || { red "R4: re-published object not fetchable from the public remote"; exit 1; }
cmp -s "$TMP/r4.dl" "$PDF_ONE" || { red "R4: re-published bytes != original"; exit 1; }
green "  ✓ R4: re-publish re-creates a fresh, fetchable public object (cycle is repeatable)"

# ===========================================================================
#  Step Q — PAGINATION. The public archive paginates at items-per-page (50)
#  with on-page controls (newer/older + numbered links). We seed 60 newest
#  items straight into the DB (cheaper than 60 uploads) so the list spans two
#  pages, then assert the controls render, the pages differ, and an out-of-
#  range cursor clamps. Done LAST so the seeded rows pollute nothing earlier.
# ===========================================================================
note "=== Step Q — archive pagination controls ==="
OWNER=$(sqlite3 "$DB" "SELECT id FROM actor WHERE local=1 LIMIT 1;")
[ -n "$OWNER" ] || { red "no local actor to own paginated test rows"; exit 1; }
{
    echo "PRAGMA busy_timeout=5000;"
    echo "BEGIN;"
    for n in $(seq -w 1 60); do
        # year 3000 ⇒ these sort newest; lexical order on the zero-padded
        # second makes pg-60 the newest and pg-01 the oldest of the batch.
        echo "INSERT INTO item (id,owner_id,object_type,name,published_at,updated_at) VALUES ('http://x/items/pg-$n','$OWNER','Note','pgitem-$n','3000-01-01T00:00:${n}Z','3000-01-01T00:00:${n}Z');"
    done
    echo "COMMIT;"
} | sqlite3 "$DB" >/dev/null
assert_sql "$DB" "SELECT count(*) FROM item WHERE id LIKE 'http://x/items/pg-%';" "60" "seeded 60 paginated rows"

# Page 1 (newest): controls present, a link to page 2, current marker = 1,
# the newest seeded row, and the "newer" step disabled (no page 0).
PG1=$(fetch_html_anon "$SOCK" "/")
assert_grep "$PG1" 'class="pagination"'            "page 1 shows pagination controls"
assert_grep "$PG1" 'href="/?page=2"'               "page 1 links to page 2"
# The NUMBERED page-2 link specifically (not just the 'older →' step button),
# which proves the ±2 window is inclusive of its upper bound — `list(lo,hi)`
# in Koka includes both ends, so page 1 of 2 shows the [1][2] numbers.
assert_grep "$PG1" '<a class="page" href="/?page=2">2</a>' "page 1 shows the NUMBERED page-2 link (inclusive window)"
assert_grep "$PG1" 'aria-current="page">1<'        "page 1 marks itself current"
assert_grep "$PG1" 'pgitem-60'                      "page 1 holds the newest seeded item"
assert_grep "$PG1" '<span class="step newer disabled"' "page 1 disables the newer step"
if printf '%s' "$PG1" | grep -q 'pgitem-01'; then
    red "page 1 leaked an item that belongs on page 2"; exit 1; fi
green "  ✓ page 1 excludes page-2 items"

# Page 2: a real "newer" link back, current marker = 2, the oldest seeded row,
# and the "older" step disabled (last page).
PG2=$(fetch_html_anon "$SOCK" "/?page=2")
assert_grep "$PG2" '<a class="step newer"'         "page 2 links back to newer"
assert_grep "$PG2" '<a class="page" href="/?page=1">1</a>' "page 2 shows the NUMBERED page-1 link"
assert_grep "$PG2" 'aria-current="page">2<'        "page 2 marks itself current"
assert_grep "$PG2" 'pgitem-01'                      "page 2 holds the oldest seeded item"
assert_grep "$PG2" '<span class="step older disabled"' "page 2 (last) disables the older step"

# Clamp: an out-of-range cursor collapses to the last page, not an empty list.
PG999=$(fetch_html_anon "$SOCK" "/?page=999")
assert_grep "$PG999" 'aria-current="page">2<'      "?page=999 clamps to the last page"
assert_grep "$PG999" 'pgitem-01'                    "clamped page still lists items"
# …and a non-positive cursor collapses to page 1.
PG0=$(fetch_html_anon "$SOCK" "/?page=0")
assert_grep "$PG0" 'aria-current="page">1<'        "?page=0 clamps to page 1"
green "  ✓ pagination cursor clamps both ends"

# ===========================================================================
#  Step S — RESPONSIVENESS MODES. The container max-width is a persisted,
#  owner-only setting (860px / 1080px / 1440px / unlimited->none), default
#  1080px, emitted by layout as an inline <style> override on EVERY page.
#  The POST validates against the closed set — the stored value lands inside
#  a <style> block, so free-form CSS must never persist.
# ===========================================================================
note "=== Step S — responsiveness modes (container width setting) ==="
S_HOME=$(fetch_html_anon "$SOCK" "/")
assert_grep "$S_HOME" '<style>body{max-width:1080px}</style>' "default container width is 1080px"
S_ANON_GET=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "http://x/settings")
[ "$S_ANON_GET" = "403" ] || { red "anon GET /settings expected 403, got $S_ANON_GET"; exit 1; }
S_ANON_POST=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --data "width=1440px" "http://x/settings")
[ "$S_ANON_POST" = "403" ] || { red "anon POST /settings expected 403, got $S_ANON_POST"; exit 1; }
green "  ✓ /settings is owner-only (anon GET + POST → 403)"
S_FORM=$(fetch_html "$SOCK" "$JAR" "/settings")
assert_grep "$S_FORM" '<select name="width">' "settings form renders the width selector"
assert_grep "$S_FORM" '<option value="1080px" selected>' "current mode (1080px) pre-selected"
S_POST=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" --data "width=1440px" "http://x/settings")
[ "$S_POST" = "303" ] || { red "owner POST width=1440px expected 303, got $S_POST"; exit 1; }
assert_grep "$(fetch_html_anon "$SOCK" "/")" '<style>body{max-width:1440px}</style>' "container width switches to 1440px site-wide"
curl -s -o /dev/null --unix-socket "$SOCK" --cookie "$JAR" --data "width=none" "http://x/settings"
assert_grep "$(fetch_html_anon "$SOCK" "/")" '<style>body{max-width:none}</style>' "unlimited mode renders max-width:none"
S_BAD=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" --data "width=666px;background:url(x)" "http://x/settings")
[ "$S_BAD" = "400" ] || { red "bogus width expected 400, got $S_BAD"; exit 1; }
assert_sql "$DB" "SELECT value FROM setting WHERE key='container_width';" "none" "bogus width NOT stored (no CSS injection into <style>)"
green "  ✓ width modes validate against the closed set"
curl -s -o /dev/null --unix-socket "$SOCK" --cookie "$JAR" --data "width=1080px" "http://x/settings"
assert_grep "$(fetch_html_anon "$SOCK" "/")" '<style>body{max-width:1080px}</style>' "container width restored to the 1080px default"

# ===========================================================================
#  Step T — MULTITENANCY. Invite-only registration; a second tenant (bob) with
#  his OWN storage backend; cross-tenant file viewing (any logged-in tenant
#  downloads any tenant's archived file, streamed through the OWNER's config);
#  and the per-item / admin authorization gates.
# ===========================================================================
note "=== Step T — multitenancy (invite → register → cross-tenant view) ==="
BOB_JAR="$TMP/bob-jar"

# (a) Admin mints an invite; anon cannot even see the page.
ANON_INV=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "http://x/invites")
[ "$ANON_INV" = "403" ] || { red "anon GET /invites expected 403, got $ANON_INV"; exit 1; }
curl -s -o /dev/null --unix-socket "$SOCK" --cookie "$JAR" --data-urlencode "note=for bob" "http://x/invites"
INVITE_TOK=$(sqlite3 "$DB" "SELECT token FROM invite WHERE used_by IS NULL ORDER BY created_at DESC LIMIT 1;")
[ -n "$INVITE_TOK" ] || { red "admin mint invite produced no open invite row"; exit 1; }
green "  ✓ admin minted an invite; anon /invites → 403"

# (b) The register page validates the token.
assert_status "$SOCK" "/register?invite=$INVITE_TOK" 200
assert_status "$SOCK" "/register?invite=deadbeefdeadbeef" 404

# (c) Username/password validation re-renders the form WITHOUT consuming the
#     invite (a rejected attempt must not burn the token).
reg() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" \
          --data-urlencode "invite=$1" --data-urlencode "username=$2" \
          --data-urlencode "password=$3" --data-urlencode "confirm=$4" "http://x/register"; }
reg "$INVITE_TOK" "alice" "hunter2hunter" "hunter2hunter" >/dev/null   # taken
reg "$INVITE_TOK" "admin" "hunter2hunter" "hunter2hunter" >/dev/null   # reserved
reg "$INVITE_TOK" "bob"   "short"         "short"         >/dev/null   # too short
assert_sql "$DB" "SELECT count(*) FROM invite WHERE token='$INVITE_TOK' AND used_by IS NULL;" "1" \
  "rejected registrations do not consume the invite"
assert_sql "$DB" "SELECT count(*) FROM actor WHERE username='admin' AND local=1;" "0" \
  "reserved username not created"

# (d) A valid registration creates the tenant, consumes the invite, opens a session.
BOB_CODE=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie-jar "$BOB_JAR" \
  --data-urlencode "invite=$INVITE_TOK" --data-urlencode "username=bob" \
  --data-urlencode "password=swordfish99" --data-urlencode "confirm=swordfish99" \
  --data-urlencode "name=Bob" "http://x/register")
[ "$BOB_CODE" = "303" ] || { red "valid register expected 303, got $BOB_CODE"; exit 1; }
assert_sql "$DB" "SELECT is_admin FROM actor WHERE username='bob' AND local=1;" "0" "bob is a non-admin tenant"
assert_sql "$DB" "SELECT count(*) FROM invite WHERE token='$INVITE_TOK' AND used_by IS NOT NULL;" "1" \
  "invite consumed on successful register"
assert_status "$SOCK" "/register?invite=$INVITE_TOK" 404
green "  ✓ registered tenant bob; the invite is single-use"

# (e) bob's session works but bob is not an admin.
BOB_INV=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$BOB_JAR" "http://x/invites")
[ "$BOB_INV" = "403" ] || { red "non-admin bob GET /invites expected 403, got $BOB_INV"; exit 1; }
green "  ✓ bob (non-admin) cannot reach /invites"

# (f) Storage POST forbids local backends, accepts named cloud remotes.
stor() { curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$BOB_JAR" \
           --data-urlencode "rclone_conf=$1" --data-urlencode "archive_remote=$2" \
           --data-urlencode "public_remote=$3" --data-urlencode "public_url_base=$4" "http://x/settings/storage"; }
[ "$(stor '' "$TMP/x" "cloud:b" '')"            = "400" ] || { red "local-path archive must be rejected"; exit 1; }
[ "$(stor 'type = local' "a:x" "b:y" '')"       = "400" ] || { red "type=local config must be rejected"; exit 1; }
[ "$(stor '[a] type = s3' "a:arch" "a:pub" '')" = "303" ] || { red "named cloud remotes must be accepted"; exit 1; }
green "  ✓ storage POST rejects local backends, accepts named cloud remotes"

# (g) Seed bob's REAL storage directly with a non-empty rclone.conf defining a
#     NAMED remote. The settings UI forbids local backends, but the test env IS
#     local — so we seed a "bobarch" local-type remote via SQL (the same shape
#     a cloud config would take). This exercises the full per-tenant path at
#     runtime: config materialisation (csrc/fs_bridge.c → a 0600 file) AND the
#     `rclone --config <that file>` invocation. Then bob uploads.
mkdir -p "$TMP/bob-archive" "$TMP/bob-public"
BOB_CONF=$'[bobarch]\ntype = local\n'
sqlite3 "$DB" "INSERT OR REPLACE INTO tenant_storage (actor_id, rclone_conf, archive_remote, public_remote, public_url_base, updated_at) VALUES ('http://localhost/users/bob', '$BOB_CONF', 'bobarch:$TMP/bob-archive', 'bobarch:$TMP/bob-public', 'http://example.test/bobdl', '2026-06-28T00:00:00Z');"
BOB_ITEM=$(upload "$SOCK" "$BOB_JAR" "$PDF_TWO" "Bob's PDF" "" "bob reviews it" "2" "")
BOB_SLUG=$(basename "$BOB_ITEM")
assert_sql "$DB" "SELECT username FROM actor a JOIN item i ON i.owner_id=a.id WHERE i.id='http://localhost/items/$BOB_SLUG';" "bob" \
  "bob's upload is owned by bob"
[ -f "$TMP/bob-archive/$BOB_SLUG" ] || { red "bob's blob should land in HIS archive remote (via --config)"; exit 1; }
# bob's config was materialised to a private 0600 file (secrets off argv/env).
BOB_CONF_FILE="$DATA/storage/http___localhost_users_bob.conf"
[ -f "$BOB_CONF_FILE" ] || { red "bob's rclone config was not materialised to a file"; exit 1; }
BOB_PERM=$(stat -f '%Lp' "$BOB_CONF_FILE" 2>/dev/null || stat -c '%a' "$BOB_CONF_FILE")
[ "$BOB_PERM" = "600" ] || { red "materialised config perms = $BOB_PERM, want 600"; exit 1; }
green "  ✓ bob uploaded via HIS rclone config (materialised 0600, passed as --config)"

# (h) THE CORE FEATURE: a DIFFERENT tenant (admin alice) downloads bob's
#     archived file — streamed through bob's config — byte-exact.
ALICE_DL=$(curl -s -o "$TMP/alice-got.pdf" -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" "http://x/items/$BOB_SLUG/file")
[ "$ALICE_DL" = "200" ] || { red "cross-tenant download expected 200, got $ALICE_DL"; exit 1; }
cmp -s "$TMP/alice-got.pdf" "$PDF_TWO" || { red "cross-tenant download bytes differ from bob's file"; exit 1; }
green "  ✓ alice downloaded bob's file, byte-exact, via bob's config"

# (i) Anon cannot download; a non-owner cannot mutate.
ANON_DL=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "http://x/items/$BOB_SLUG/file")
[ "$ANON_DL" = "403" ] || { red "anon file download expected 403, got $ANON_DL"; exit 1; }
ALICE_PUB=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" --data "" "http://x/items/$BOB_SLUG/publish-file")
[ "$ALICE_PUB" = "403" ] || { red "non-owner publish expected 403, got $ALICE_PUB"; exit 1; }
green "  ✓ anon download forbidden; a non-owner cannot publish/mutate bob's item"

# (j) The shared archive attributes each item to its author. Use search (a
#     deterministic single-item result) rather than the global feed, which
#     paginates and ties on same-second timestamps in the hermetic run.
assert_grep "$(fetch_html_anon "$SOCK" "/search?q=Bob")" 'by <a href="/users/bob">bob</a>' \
  "search attributes bob's item to bob"
green "  ✓ the shared archive attributes items across tenants"

green ""
green "=========================================="
green "  e2e (socket) passed.  data dir: $DATA"
green "  daemon log: $LOG"
green "=========================================="
