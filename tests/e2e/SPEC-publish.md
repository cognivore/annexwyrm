# SPEC — PUBLISH / UNPUBLISH federation-emission e2e journey for annexwyrm

**File to produce:** the new journey is **appended to `tests/e2e/run.sh`**, after its existing flow (currently ending at the green "e2e passed" banner). Add the steps *before* that banner, or move the banner to the very end. No new files; reuse `tests/e2e/lib.sh` helpers and add small new helpers there only where this spec explicitly calls for one.
**Audience:** the engineer who extends the suite.
**Status of this document:** normative. Every "MUST" is a hard assertion the test is required to make. "If it didn't crash, ship it" is **forbidden**: each step asserts an exact, observable fact — an HTTP status, a specific header, a literal HTML substring, an exact SQL result, or an exact daemon-log line shape. A step that merely runs a command and checks `$? == 0` does not satisfy this spec.

---

## 0. Why this journey exists (read before writing a line)

The existing `run.sh` exercises **ingest** (upload) and **read** (anonymous browse) thoroughly, but the **outbox** — the federation-emission machinery — has **zero behavioral coverage through real HTTP**. `emit-create` (via `ship-activity`) and `emit-delete` are only ever exercised, today, by code that no test drives end to end. The two POST endpoints that fire them —

- `POST /items/<id>/publish`  → `handle-item-publish` → `publish-item` → `save-item` → `emit-create`
- `POST /items/<id>/unpublish` → `handle-item-unpublish` → `emit-delete` → `unpublish-item` → `save-item`

(see `src/web/route.kk` lines 77–80 and `src/web/handler/item.kk` lines 36–64)

— turn a real session POST into (a) a privacy state change written back to the `item` row, (b) an AP activity row in the `activity` table, (c) zero-or-more `delivery` rows, and (d) one structured log line on **stderr**. None of that is currently asserted. This journey closes the gap: it drives the **actual endpoints** with the **already-logged-in session** from `run.sh`, and asserts all four observable surfaces at each step.

The single most important behavioral fact this journey pins down — and the one most likely to be silently broken by a future refactor — is the **delivery-row count of exactly zero** on a single-actor instance with no followers (§4, Step P3). The outbox *builds* a Create activity addressed to `Public` + the followers collection; `resolve-recipients` then expands that to inbox URLs by querying the DB. With no accepted followers, that expansion is the empty list, and `queue-many` inserts nothing. Asserting **exactly 0** (not "≤ some number", not "it didn't error") is what catches a regression that, say, starts queuing a delivery to the literal `…#Public` string or to the actor's own inbox.

The second non-obvious fact: **unpublish does NOT tombstone the item row.** Read `handle-item-unpublish` and `unpublish-item` (`src/annex/publish.kk` lines 71–81): it emits a `Delete` *activity* (so federated copies tombstone), but locally it merely flips `privacy` back to `ItPrivate` and bumps `updated_at`. The `item` row **survives, in place, with the same `id`**, now private. This spec asserts that survival explicitly (§4, Step U3): the 404 an anonymous visitor gets afterward is an **authorization** decision, not data loss.

---

## 1. Scope and non-goals

**In scope — the PUBLISH / UNPUBLISH journey, appended to `run.sh`'s existing flow:**

1. **Pick the publish subject** (see §3): reuse the **private** item `run.sh` already uploaded (`PRIVATE_PATH` / `PRIVATE_URL`). It is already owned by the logged-in session and is already `privacy='private'`, so it is the natural, zero-extra-state subject for a publish→unpublish cycle. No fresh upload is needed or justified; introducing one would only add an unrelated `upload/done` log line and a second item to disambiguate in every SQL `WHERE`. (Decision recorded here so the next maintainer does not "fix" it by uploading a fresh item.)
2. **Capture a clean DB baseline** for `activity`, `delivery`, and the subject's `privacy`, **before** publishing — so every post-action assertion is a *delta*, not an absolute that could be satisfied by leftover state.
3. **PUBLISH** the private item via `POST $PRIVATE_PATH/publish` with the session cookie. Assert the client response, the daemon log, the `item` row transition, the new `Create` activity row, and the **exact** delivery-row count.
4. **Verify public visibility over HTTP**: the item that was 404 to anon is now 200, and renders the public-state markers.
5. **UNPUBLISH** via `POST $PRIVATE_PATH/unpublish`. Assert the client response, the daemon log, the new `Delete` activity row, the delivery-row count, the **revert-to-private** `item` transition, and that **the row still exists**.
6. **Verify re-hidden over HTTP**: anonymous GET is 404 again, with no content leak.

**Out of scope:** TLS/Caddy (that is `SPEC-caddy.md`'s job — this journey talks to the Unix socket directly, exactly like the rest of `run.sh`); actual outbound HTTP delivery to remote inboxes; the `update` endpoint; multi-actor / real followers; the JSON-LD representation of the item (`Accept: application/activity+json`) beyond what is needed to assert the `activity.raw` blob.

**No new daemon, no new data dir.** This journey runs against the **same** daemon, socket (`$SOCK`), cookie jar (`$JAR`), and DB (`$DATA/annexwyrm.db`) that `run.sh` already stood up. It is a continuation, not a fixture of its own.

---

## 2. Environment, invocation, knobs

- Inherits `run.sh`'s shell: `set -euo pipefail`, the `trap cleanup EXIT INT TERM`, the Nix dev shell (`curl`, `sqlite3`, `python3`, `nc`). No installs.
- Reuses the established globals from `run.sh`: `$SOCK`, `$JAR`, `$DATA`, `$LOG`, `$PRIVATE_PATH`, `$PRIVATE_URL`, `$PUBLIC_PATH`, `$PUBLIC_URL`.
- **The daemon's log goes to stderr now**, and `run.sh` captures it with `"$BINARY" serve > "$LOG" 2>&1 &`. So `$LOG` contains the log lines this journey asserts. (See `src/interp/log_console.kk`: `kk-aw-log-line` writes one line to stderr and flushes; the comment there documents *why* — stdout buffering hid lines in the redirected file. Do **not** grep stdout for these; grep `$LOG`.)
- **Log line format** (from `with-console-log`, `src/interp/log_console.kk` lines 24–26): one line per `emit`, shaped `[<level>] <msg> <k1>=<v1> <k2>=<v2> …`. The level token is **lowercase** — `log-level/show LogInfo == "info"`, so the line begins `[info] `, **not** `[INFO]`. Field values are inserted verbatim with no quoting. The journey MUST match the lowercase `[info]` prefix; matching `[INFO]` will silently never fire.
- **A SQL helper.** The journey makes several single-value SQL assertions. Add to `lib.sh` a helper of this shape (sibling to the existing `assert_*`):
  ```bash
  # assert_sql DB SQL EXPECTED LABEL — run a scalar query, compare exactly.
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
  ```
  It MUST print the query and both values on failure (failure ergonomics, §6). All `(c)` assertions below are expressed against it.
- **A daemon-log helper.** Add a helper that fails loudly with context:
  ```bash
  # assert_log_grep LOGFILE PATTERN LABEL — fail unless PATTERN (grep -E) is in LOGFILE.
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
  ```
- **A POST-and-capture helper for the action endpoints.** The publish/unpublish endpoints take an **empty-body POST with the session cookie**, and reply `303` with a `Location` and no body of interest. Add:
  ```bash
  # post_action SOCK JAR PATH → echoes "STATUS<TAB>LOCATION" (Location CR-stripped).
  # POSTs an empty body carrying the cookie jar; does NOT follow redirects.
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
  ```
  Header parsing is `grep -i` + `sed` (BSD-awk-proof; do **not** copy `upload`'s `awk IGNORECASE` trick — it is a no-op on macOS awk, per the existing house notes in `lib.sh`).

---

## 3. The subject and the identities, fixed once

The journey operates on **one** item and asserts against **one** local actor. Pin both as shell vars at the top of the appended section so every assertion reuses them:

- `SUBJECT_PATH="$PRIVATE_PATH"`  — the path (`/items/<hex>`) returned by the original upload.
- `SUBJECT_URL="$PRIVATE_URL"`    — i.e. `http://localhost$PRIVATE_PATH`. **This is the item's stored `id`** (item ids are minted as `get-base-url() ++ "/items/" ++ slug`, and `run.sh` runs `init`/`serve` with `ANNEXWYRM_BASE_URL=http://localhost`, no port). Every `item`/`activity` row keyed on the item references this exact string. Keep base-URL (`http://localhost…`, the stored identity) and transport (`--unix-socket "$SOCK"`, `http://x<path>`) straight: we **fetch** by `http://x$SUBJECT_PATH` over the socket, but we **assert** the stored/linked id as `$SUBJECT_URL`.
- `ACTOR_URL="http://localhost/users/alice"` — `local-actor-url() = get-base-url() ++ "/users/" ++ get-local-username()`; `run.sh` inits with `ANNEXWYRM_USERNAME=alice`. This is the `item.owner_id`, the `activity.actor_id` for both the Create and the Delete, and the `delivery.sender_id` (had any delivery existed). Derive it once; do not re-type `http://localhost/users/alice` inline.
- `DB="$DATA/annexwyrm.db"`.

---

## 4. The journey, step by step, with their three observable truths

For each step: **(a)** what the client sees (status, `Location`, HTML markers), **(b)** what the daemon logs (exact line shape, on stderr → `$LOG`), **(c)** what the DB holds (exact SQL + expected value).

### Step P0 — Baseline (capture deltas, not absolutes)

Before any publish. No client action; this is a measurement.

- **(a)** n/a.
- **(b)** n/a.
- **(c)** Capture and assert the starting state so later deltas are unambiguous:
  - `ACT_BEFORE=$(sqlite3 "$DB" "SELECT count(*) FROM activity;")` — remember it.
  - `DEL_BEFORE=$(sqlite3 "$DB" "SELECT count(*) FROM delivery;")` — remember it.
  - The subject is genuinely private to start:
    `assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" "private" "subject starts private"`.
  - There is **no** Create activity for this object yet:
    `assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "0" "no pre-existing Create"`.
  - **There are zero accepted followers** — the reason the delivery count will be zero. Assert it as a documented precondition, not an assumption:
    `assert_sql "$DB" "SELECT count(*) FROM follow WHERE target_id='$ACTOR_URL' AND state='accepted';" "0" "zero accepted followers (single-actor instance)"`.
    (`followers-inboxes` in `ap/persist.kk` selects exactly `follow` rows with `state='accepted'` joined to a cached `actor`; with none, it returns `[]`, so `resolve-recipients` → `[]`, so `queue-many` inserts nothing. This assertion is *why* "delivery count == 0" below is the correct expectation.)

### Step P1 — PUBLISH: the client sees a 303 to the item

`post_action "$SOCK" "$JAR" "$SUBJECT_PATH/publish"` (empty-body POST, session cookie, no redirect-follow).

**Assertions:**
- **(a)**
  - Status MUST be `303`. (`handle-item-publish` ends in `see-other("/items/" ++ id)`; `see-other` is `303 See Other` — `src/web/server.kk`.) A `200` here means the auth gate fired (`is-owner-session` false) and the handler returned `forbidden`/`not-found` instead — fail with the captured status.
  - `Location` header MUST equal exactly `$SUBJECT_PATH` (i.e. `/items/<hex>`). The handler redirects to the *path* `"/items/" ++ id`, where `id` is the URL segment (the slug), so `Location` is `$SUBJECT_PATH`, not the absolute `$SUBJECT_URL`. Assert string equality.
- **(b)** The publish path runs `emit-create → ship-activity`, which logs (outbox.kk lines 102–104):
  `info("outbox/publish", [("id", act.id), ("type", act.kind.show), ("recipients", inboxes.length.show)])`.
  Rendered to `$LOG` as exactly:
  `[info] outbox/publish id=<activity-id> type=Create recipients=0`
  Assert with `assert_log_grep "$LOG" '^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Create recipients=0' "publish emission"`.
  - The `recipients=0` token MUST be asserted **literally** — this is the log-side mirror of the zero-delivery invariant. A line with `recipients=1` (or any nonzero) is a regression even though the HTTP status is unchanged.
  - The activity id matches `http://localhost/activities/<hex>` because `mint-id("activities")` = `get-base-url() ++ "/activities/" ++ rand-hex(12)`.
- **(c)** Exactly **one** new `Create` activity row exists for this object, shaped correctly:
  - Count went up by exactly one Create:
    `assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "1" "one Create activity for subject"`.
  - Its actor is the local actor (Create's `actor` = `item.owner`, via `create-of`):
    `assert_sql "$DB" "SELECT actor_id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "$ACTOR_URL" "Create actor = local actor"`.
  - Its `object_id` linkage points at the item (extracted from the embedded object's `id` by `record-activity`'s use of `a.object-id`):
    `assert_sql "$DB" "SELECT object_id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "$SUBJECT_URL" "Create object_id = item id"`.
  - It is an **outbound** activity (`inbox_remote=0`; `record-activity` is called with `False`):
    `assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "0" "Create is outbound"`.
  - Its activity id has the minted shape (defends against a malformed/empty id silently stored):
    `assert_sql "$DB" "SELECT id GLOB 'http://localhost/activities/*' FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "1" "Create id is minted activity URL"`.
  - The raw JSON-LD blob embeds the object and records it as a `Create`. Assert the raw text contains both the activity type and the object id:
    `assert_sql "$DB" "SELECT raw LIKE '%\"type\":\"Create\"%' AND raw LIKE '%$SUBJECT_URL%' FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';" "1" "Create raw contains type+object id"`.
- **(c) — delivery rows == follower-inbox count == EXACTLY 0.** This is the headline invariant.
  - `assert_sql "$DB" "SELECT count(*) FROM delivery;" "$DEL_BEFORE" "publish queued zero deliveries (delta == 0)"`
    — the total delivery count is **unchanged** from the P0 baseline. With zero accepted followers and a Create addressed only to `…#Public` + the followers collection, `resolve-recipients` yields the empty inbox list, so `queue-many` inserts no rows.
  - Belt-and-braces, scoped to *this* Create's activity id (which we can fetch): there are **zero** delivery rows whose `activity_id` is the new Create. Express as:
    ```bash
    CREATE_AID=$(sqlite3 "$DB" \
      "SELECT id FROM activity WHERE type='Create' AND object_id='$SUBJECT_URL';")
    assert_sql "$DB" "SELECT count(*) FROM delivery WHERE activity_id='$CREATE_AID';" "0" \
      "exactly zero deliveries for the Create activity"
    ```
    **Why exactly 0 and not some other number:** the only delivery targets are follower inboxes (the explicit-recipient branch is empty because the addressing is `Public`/followers, never a bare remote actor id), and `followers-inboxes` returns `[]` for an instance with no `state='accepted'` follow rows (asserted in P0). Therefore the expected, exact, justified count is **0**.

### Step P2 — PUBLISH: the item row transitioned to public

Still no new client action; assert the write-back from `publish-item → save-item`.

- **(a)** n/a (covered by P3's HTTP visibility check).
- **(b)** n/a.
- **(c)**
  - Privacy is now public (`handle-item-publish` hardcodes `privacy-str="public"` → `ItPublic`; `publish-item` sets it; `privacy/show ItPublic == "public"`):
    `assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" "public" "subject is now public"`.
  - The row is the **same row** — same id, still exactly one item with this id (publish must not mint a duplicate):
    `assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL';" "1" "still exactly one item row"`.
  - `updated_at` advanced past `published_at` (publish bumps `now`; `publish-item` keeps `published-at`, sets `updated-at = now`):
    `assert_sql "$DB" "SELECT updated_at > published_at FROM item WHERE id='$SUBJECT_URL';" "1" "updated_at advanced on publish"`.

### Step P3 — PUBLISH: the item is now publicly visible over HTTP

Anonymous GET (no cookie jar — use `fetch_html_anon` / `assert_status` from `lib.sh`) against the socket.

**Assertions:**
- **(a)**
  - `assert_status "$SOCK" "$SUBJECT_PATH" 200` — the item that was `404` to anon in `run.sh`'s earlier assertion is now reachable. (`handle-item` returns `not-found` only when `privacy.show == "private" && !is-owner-session`; now public, the anon branch renders the page.)
  - Fetch the HTML anon: `PUB_HTML=$(fetch_html_anon "$SOCK" "$SUBJECT_PATH")` and assert the **public-state** markers, each separately, with `assert_grep`:
    - `assert_grep "$PUB_HTML" '<span class="privacy">public</span>' "privacy meta shows public"` — the item-page meta line renders `esc(i.privacy.show)` inside `<span class="privacy">` (`src/web/html/item.kk` line 23).
    - `assert_grep "$PUB_HTML" '/unpublish" method="post"' "publish state offers the unpublish action"` — `actions-block` renders the **unpublish** form for any non-`ItPrivate` item (lines 89–94); the presence of `/unpublish` (and absence of `/publish`, below) is the page-level proof the item is in a federated state.
    - `assert_grep "$PUB_HTML" 'Private PDF' "subject title still renders"` — confirms we are looking at the right item (its name is `Private PDF` from the original upload).
  - Negative marker — the publish action form MUST be **gone** (only the private branch renders it):
    `if printf '%s' "$PUB_HTML" | grep -q '/publish" method="post"'; then red "published item still shows a publish form"; exit 1; fi` (or an `assert_absent` helper if you add one). This proves the page reflects the *new* state, not a cached private render.
- **(b)** The `GET /items/<id>` render path is pure (no `log` effect on the read), so it emits **no** new log line of interest. Do not assert a log line here; assert instead that the daemon is **still alive** after the request: `kill -0 "$DAEMON_PID"`. (A render that crashed the daemon would otherwise pass an HTTP-less check.)
- **(c)** n/a (state already asserted in P2).

### Step U1 — UNPUBLISH: the client sees a 303 to the item

`post_action "$SOCK" "$JAR" "$SUBJECT_PATH/unpublish"` (empty-body POST, session cookie, no redirect-follow).

**Read the handler ordering before asserting (`handle-item-unpublish`, item.kk lines 52–64): it calls `emit-delete(it)` on the still-loaded (public) item FIRST, then `unpublish-item → save-item`.** So the Delete activity is emitted while the item is still public, and the local revert-to-private happens after. Both effects are committed by the time the 303 is returned.

**Assertions:**
- **(a)**
  - Status MUST be `303` (`see-other("/items/" ++ id)`).
  - `Location` MUST equal exactly `$SUBJECT_PATH`.
- **(b)** `emit-delete` logs (outbox.kk line 117): `info("outbox/delete", [("id", aid)])` — note it logs **only** the `id` field (no `type`, no `recipients`, unlike `outbox/publish`). Rendered to `$LOG` as exactly:
  `[info] outbox/delete id=<activity-id>`
  Assert: `assert_log_grep "$LOG" '^\[info\] outbox/delete id=http://localhost/activities/[0-9a-f]+$' "delete emission"`.
  - The trailing `$` matters: it asserts the line ends right after the id, proving the Delete log carries no recipients field — matching the code, and catching any future "helpfully add recipients=" drift that would change the contract.
- **(c)** Exactly **one** new `Delete` activity row for this object:
  - `assert_sql "$DB" "SELECT count(*) FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" "1" "one Delete activity for subject"`.
  - Delete's `actor_id` is the local actor (`delete-of(aid, item.owner, item.id, …)`):
    `assert_sql "$DB" "SELECT actor_id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" "$ACTOR_URL" "Delete actor = local actor"`.
  - Delete's `object_id` is the item id (Delete's `object` is the bare id string `item.id`; `record-activity` stores `a.object-id` which for a `JString` is the string itself):
    `assert_sql "$DB" "SELECT object_id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" "$SUBJECT_URL" "Delete object_id = item id"`.
  - Outbound: `assert_sql "$DB" "SELECT inbox_remote FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';" "0" "Delete is outbound"`.
  - The **Create row from P1 still exists** alongside it — emitting Delete does not retract the Create:
    `assert_sql "$DB" "SELECT count(*) FROM activity WHERE object_id='$SUBJECT_URL' AND type IN ('Create','Delete');" "2" "both Create and Delete recorded for subject"`.
- **(c) — delivery rows for the Delete == EXACTLY 0**, same justification as P1 (Delete is addressed to `Public`+followers via `build-addressing(ItPublic, …)`; no accepted followers ⇒ empty inbox list ⇒ no rows):
  ```bash
  DELETE_AID=$(sqlite3 "$DB" \
    "SELECT id FROM activity WHERE type='Delete' AND object_id='$SUBJECT_URL';")
  assert_sql "$DB" "SELECT count(*) FROM delivery WHERE activity_id='$DELETE_AID';" "0" \
    "exactly zero deliveries for the Delete activity"
  ```
  And the global delivery total is **still** the P0 baseline (no publish or unpublish in this whole journey queued anything):
  `assert_sql "$DB" "SELECT count(*) FROM delivery;" "$DEL_BEFORE" "delivery table unchanged across publish+unpublish"`.

### Step U2 — UNPUBLISH: the item row reverted to private AND the row survives (tombstone semantics)

This is the explicit assertion of the "does it tombstone?" question. **It does not.** `unpublish-item` builds a new `Annex-item` with `ItPrivate` and the same `id`/owner/name/content/etc., and `save-item` does `INSERT OR REPLACE` keyed on `id` — so the row is rewritten in place, still present.

- **(a)** n/a (HTTP behavior in U3).
- **(b)** n/a.
- **(c)**
  - The item row **still exists** (the load-bearing tombstone assertion — the local row is not deleted):
    `assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL';" "1" "item row survives unpublish (no local tombstone)"`.
  - Its privacy reverted to private (`unpublish-item` → `ItPrivate`; `privacy/show ItPrivate == "private"`):
    `assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" "private" "subject reverted to private"`.
  - The item's identifying content survived the round trip (proves it is a privacy flip, not a stubbed/blanked tombstone):
    `assert_sql "$DB" "SELECT name FROM item WHERE id='$SUBJECT_URL';" "Private PDF" "item name preserved through unpublish"`.
  - `updated_at` advanced again (unpublish bumps `now` once more; it MUST be ≥ the value after publish — at minimum, still ≥ `published_at`):
    `assert_sql "$DB" "SELECT updated_at >= published_at FROM item WHERE id='$SUBJECT_URL';" "1" "updated_at advanced on unpublish"`.

  > **Spec-vs-code note (normative):** the prompt asked, if unpublish does NOT tombstone but reverts to private, to spec what the code actually does. It reverts to private. There is **no** local `Tombstone` object and **no** `DELETE FROM item`. The *Delete activity* (U1) is the federation-level tombstone signal sent to remotes; the local representation is simply a private item. The test MUST assert the row's continued existence and `privacy='private'` — it MUST NOT assert any tombstone/`Deleted` marker on the `item` row, because none is written.

### Step U3 — UNPUBLISH: the item is hidden from anonymous HTTP again, with no leak

Anonymous GET (no cookie jar).

**Assertions:**
- **(a)**
  - `assert_status "$SOCK" "$SUBJECT_PATH" 404` — anon now gets `404`, not `403` (`handle-item` returns `not-found("no such item")` for a private item to a non-owner, deliberately not distinguishing "exists but forbidden" from "absent", to avoid leaking existence).
  - Fetch the anon body and assert the not-found marker **and** the absence of any private content leak:
    ```bash
    GONE_HTML=$(fetch_html_anon "$SOCK" "$SUBJECT_PATH")
    assert_grep "$GONE_HTML" "no such item" "404 body says no such item"
    ```
    and a negative check that the private content/title did NOT leak into the 404 page:
    ```bash
    if printf '%s' "$GONE_HTML" | grep -q 'Private PDF'; then
        red "404 page leaked the private item's title"; exit 1; fi
    if printf '%s' "$GONE_HTML" | grep -q 'This stays with alice'; then
        red "404 page leaked the private item's content"; exit 1; fi
    ```
    (`This stays with alice` is the private item's body from `run.sh`'s upload — assert it is absent.)
  - **Owner can still see it (authorization, not deletion).** Re-fetch the same path **with the session jar** and assert `200`:
    `assert_status_owner` — i.e. `code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --cookie "$JAR" "http://x$SUBJECT_PATH")` MUST be `200`. This closes the loop: the 404 is purely an anonymous-authorization outcome (`is-owner-session` true ⇒ the private item renders), proving the row is intact and the unpublish did not destroy it. The owner page MUST again show the **publish** action form (back to the private branch of `actions-block`):
    `OWNER_HTML=$(fetch_html "$SOCK" "$JAR" "$SUBJECT_PATH")` then `assert_grep "$OWNER_HTML" '/publish" method="post"' "owner sees publish action again (item is private)"`.
- **(b)** Read render is pure; assert only that the daemon is still alive: `kill -0 "$DAEMON_PID"`.
- **(c)** The private item still in the table (re-affirm survival from the DB side after the HTTP round trip):
  `assert_sql "$DB" "SELECT count(*) FROM item WHERE id='$SUBJECT_URL' AND privacy='private';" "1" "private item persists after unpublish round-trip"`.

---

## 5. Authorization edge (must include — proves the gate is real)

Both endpoints are owner-gated (`if !is-owner-session(req) then forbidden("login required")`). The journey MUST prove that gate fires, so the success-path 303s above are not accidentally reachable by anyone.

- **Anonymous publish is forbidden.** `code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" --request POST --data '' "http://x$SUBJECT_PATH/publish")` MUST be `403`, and the body MUST contain `login required`:
  - `assert_status`-style: status `403` (`forbidden(...)` ⇒ 403; confirm via `src/web/server.kk`).
  - `assert_grep "$(curl -s --unix-socket "$SOCK" -X POST --data '' "http://x$SUBJECT_PATH/unpublish")" "login required" "anon unpublish refused"`.
- **(c)** After the anonymous attempts, **no** new activity rows were created — the count of Create+Delete for the subject is still `2` (from P1+U1), not `3` or `4`:
  `assert_sql "$DB" "SELECT count(*) FROM activity WHERE object_id='$SUBJECT_URL' AND type IN ('Create','Delete');" "2" "anon attempts emitted no activities"`.
  And the item privacy is unchanged (`private`) — the rejected publish did not flip it:
  `assert_sql "$DB" "SELECT privacy FROM item WHERE id='$SUBJECT_URL';" "private" "anon publish did not change privacy"`.

  Place this edge step **after** U3 (so it runs against the final private state) — an anonymous `publish` attempt that erroneously succeeded would flip privacy back to public, which this asserts it does not.

---

## 6. Failure ergonomics (non-negotiable)

- Every assertion failure MUST print: what was expected, what was observed, and context — for SQL, the query and both values (`assert_sql` does this); for HTTP, the status and (on body assertions) the first ~40 lines of the response (mirror `assert_grep`'s existing dump); for log assertions, the tail of `$LOG` (`assert_log_grep` does this).
- The journey runs **inside `run.sh`** and inherits its `trap cleanup`. On any failure the harness already tears down the daemon and (unless `KEEP_TMP=1`) the temp dir. Because the log assertions depend on `$LOG`, a failing log step SHOULD `tail "$LOG"` to stderr (the helper does) so CI logs are self-contained.
- The journey MUST be **order-independent of wall-clock**: never assert an exact timestamp; assert only the ordering relations (`updated_at > published_at`, `updated_at >= published_at`). SQLite string-compares ISO-8601 lexicographically, which is the intended ordering (per `sql/schema.sql`'s timestamp convention).
- Print a `note "=== PUBLISH / UNPUBLISH federation journey ==="` banner before Step P0 so the section is locatable in the run log, and a `green` per-step ✓ as the existing helpers already do.

---

## 7. Definition of done

The journey passes **iff** every MUST above holds. To have *earned its place*, it MUST go red under each of these deliberate sabotages:

1. **Make publish queue a spurious delivery** (e.g. have `resolve-recipients` keep the `…#Public` IRI or the actor's own inbox) → Step P1 `recipients=0` log assertion **and** the "exactly zero deliveries for the Create" SQL assertion MUST fail.
2. **Skip `emit-create`** in `handle-item-publish` → Step P1's "one Create activity for subject" SQL assertion and the `outbox/publish` log assertion MUST fail.
3. **Make unpublish actually `DELETE FROM item`** (tombstone the row) → Step U2's "item row survives unpublish" and Step U3's owner-`200` assertions MUST fail.
4. **Make unpublish skip `emit-delete`** → Step U1's "one Delete activity" SQL assertion and the `outbox/delete` log assertion MUST fail.
5. **Drop the owner gate** on publish (let anon through) → Step 5's `403` / `login required` assertions MUST fail.
6. **Log `[INFO]` (uppercase) instead of `[info]`** → the `outbox/publish` / `outbox/delete` log assertions MUST fail (this guards the stderr/lowercase contract documented in `log_console.kk`).

If any of those six sabotages does **not** turn the journey red, the journey does not meet this spec.

---

## Appendix A — exact strings the journey asserts (copy targets)

| Where | Literal / pattern to assert |
|---|---|
| Publish redirect status | `303` |
| Publish/unpublish `Location` | `$SUBJECT_PATH` (i.e. `/items/<hex>`), exact equality |
| Publish log line | `^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Create recipients=0` |
| Delete log line | `^\[info\] outbox/delete id=http://localhost/activities/[0-9a-f]+$` |
| Create activity row | `type='Create'`, `actor_id=$ACTOR_URL`, `object_id=$SUBJECT_URL`, `inbox_remote=0` |
| Delete activity row | `type='Delete'`, `actor_id=$ACTOR_URL`, `object_id=$SUBJECT_URL`, `inbox_remote=0` |
| Delivery rows (each activity) | `count = 0` (and `delivery` total unchanged from baseline) |
| Item after publish | `privacy='public'`, exactly one row, `updated_at > published_at` |
| Item after unpublish | row exists, `privacy='private'`, `name='Private PDF'` preserved |
| Published item page (anon) | `200`; body has `<span class="privacy">public</span>` and `/unpublish" method="post"`; body has NO `/publish" method="post"` |
| Unpublished item page (anon) | `404`; body has `no such item`; body has NO `Private PDF` / `This stays with alice` |
| Unpublished item page (owner) | `200`; body has `/publish" method="post"` |
| Anon publish/unpublish | `403` + `login required`; no activity rows added; privacy unchanged |

## Appendix B — grounding map (why each asserted fact is real, not guessed)

| Asserted fact | Source of truth |
|---|---|
| publish hardcodes `public`, calls `emit-create`, 303 to `/items/<id>` | `src/web/handler/item.kk` `handle-item-publish` (lines 36–50) |
| unpublish emits Delete first, then reverts to private; 303 | `src/web/handler/item.kk` `handle-item-unpublish` (lines 52–64) |
| `publish-item` → `ItPublic`, bumps `updated-at`; `unpublish-item` → `ItPrivate`, same id | `src/annex/publish.kk` (lines 46–81) |
| `emit-create` log `outbox/publish id/type/recipients`; `emit-delete` log `outbox/delete id` only | `src/ap/outbox.kk` (lines 102–104, 117) |
| Create `actor=item.owner`, object=embedded; Delete `object=item.id` string | `src/ap/activity.kk` `create-of` (127), `delete-of` (151); `object-id` accessor (30) |
| activity row columns (`type`,`actor_id`,`object_id`,`inbox_remote`,`raw`) + `INSERT OR IGNORE` | `src/ap/persist.kk` `record-activity` (27–38); `sql/schema.sql` `activity` (96–106) |
| delivery rows only from follower inboxes; `state='accepted'` join; empty ⇒ none | `src/ap/outbox.kk` `resolve-recipients` (30–38), `queue-many` (51–59); `src/ap/persist.kk` `followers-inboxes` (64–72) |
| delivery row columns | `src/ap/persist.kk` `queue-delivery` (41–50); `sql/schema.sql` `delivery` (144–153) |
| item row `INSERT OR REPLACE` on `id` (survives unpublish) | `src/web/handler/item.kk` `save-item` (128–142); `sql/schema.sql` `item` (58–73) |
| item page privacy meta + publish/unpublish action forms | `src/web/html/item.kk` (lines 21–23, 80–94) |
| anon private item → `not-found("no such item")` (404); owner sees it | `src/web/handler/item.kk` `handle-item` (24–34), `is-owner-session` (182–191) |
| owner gate → `forbidden("login required")` (403) on publish/unpublish | `src/web/handler/item.kk` (lines 38, 54) |
| `[info]` lowercase, one line, `[lvl] msg k=v`, stderr+flush | `src/effects/log.kk` (15–19); `src/interp/log_console.kk` (21–28) |
| base url `http://localhost`, user `alice`, item id = base ++ `/items/` ++ slug | `tests/e2e/run.sh` (init/serve env, 90–113); `src/web/handler/upload.kk` `ingest` (66–69); `src/ap/persist.kk` `local-actor-url`/`mint-id` (18–24) |
