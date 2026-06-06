# SPEC — annexwyrm's file-publication model

**File to produce:** this document is the normative specification for the **file-publication** model. It governs source changes across `src/`, `sql/`, `csrc/`, and the three e2e suites under `tests/e2e/`. Save as `tests/e2e/SPEC-file-publication.md`.
**Audience:** the engineer who lands the model and the engineer who rewrites the suites.
**Status of this document:** normative. Every "MUST" is a hard requirement. "If it didn't crash, ship it" is **forbidden**: every test step asserts an exact, observable fact — an HTTP status, a literal header, a literal HTML substring, an exact SQL scalar, an exact daemon-log line shape, or exact bytes on disk. A step that runs a command and checks only `$? == 0` does **not** satisfy this spec.

---

## 0. The product decision (read before touching a line)

annexwyrm is a **single-tenant public review site**. There is exactly one local actor; everything that actor publishes is meant to be read.

Item-level privacy (`public` / `unlisted` / `private` per item) is the **wrong** model and **dies entirely**. It is replaced by a single, narrower gate on **the file blob**, not the review.

The two facts that the whole model rests on:

1. **Every item is always public and federates immediately.** The review — title, abstract/content-warning, body, rating, `in_reply_to`, metadata — is public the instant it is uploaded. Upload itself emits the AP `Create` (this is a change: today upload emits nothing; `publish` does). There is no longer any "draft" or "private" item state, no owner-only item view, no 404-for-private authorization branch.
2. **The only thing gated is the file blob** (the PDF / EPUB / voice note / podcast — possibly secret research whose key results the public review merely *mentions*). The blob has exactly two states:

   - **`file_published = 0` ("archived") — the default.** On upload the blob is rcloned to the **encrypted archive remote** and **that is the only place it goes**. The item page shows the full review but **no download link** — a quiet "file archived, not published" state. Nothing about the blob appears in the federated object's `url` array.
   - **`file_published = 1` ("published").** Chosen at upload (a "publish file now" checkbox, **default OFF**) or on **any later day** via a publish-file action on the item page. The blob is **also** rcloned to the **public remote**, a shareable URL is minted, stored on the item, rendered as the download link, added to the AP object's `url` array, and an **`Update`** activity goes out to followers.

For v1 the publish-file transition is **one-way** (no unpublish-file) **unless this spec finds unpublish trivial** — and §8 finds it is **not** trivial (it requires deleting from the public remote, retracting a minted-link state, and an `Update` that *shrinks* `url`); v1 therefore ships publish-file only. The route and UI affordance for unpublish-file are explicitly out of scope; a future spec adds them.

### What this replaces (the old privacy flow, deleted)

The current `POST /items/<id>/publish` (privacy flip → `ItPublic` + `emit-create`) and `POST /items/<id>/unpublish` (privacy flip → `ItPrivate` + `emit-delete`) semantics are **removed**. They are replaced by:

- **upload always emits `Create`** (was: nothing);
- a new **`POST /items/<id>/publish-file`** that emits `Update` with the blob URL added (was: `publish` flipping privacy and emitting `Create`).

§6 names every privacy touchpoint, file:line, and its disposition.

---

## 1. Data model

### 1.1 The `item` table

The privacy column is **retired from all reads and writes**. A new column `file_published` is added.

**Decision (normative): keep `privacy` as a dead column on existing DBs, but stop emitting it in the fresh schema.** Rationale: all three live instances are essentially fresh, but the migration path (§1.3) must be idempotent and must not depend on SQLite's `DROP COLUMN` (added in 3.35; the bundled `csrc` SQLite version is not guaranteed across the darwin/Ubuntu build matrix). So:

- **Fresh schema** (`sql/schema.sql` and the embedded `ANNEXWYRM_SCHEMA` in `csrc/db_bridge.c`): the `item` table is created **without** a `privacy` column and **with** `file_published`. A fresh `init` therefore has no `privacy` column at all.
- **Migration** (existing DBs that still have `privacy`): the column is left in place (never dropped), but no code reads or writes it. `ALTER TABLE item ADD COLUMN file_published` is applied idempotently (§1.3). A migrated DB ends up with a dead `privacy` column and a live `file_published`; a freshly-`init`ed DB has only `file_published`. Both are valid and behave identically because **no code references `privacy`**.

This split (drop in fresh schema, keep-dead in migration) is the only way to keep the fresh schema clean *and* keep the migration `DROP COLUMN`-free *and* keep both schema sources byte-coherent. The fresh `item` table is:

```sql
CREATE TABLE IF NOT EXISTS item (
    id              TEXT PRIMARY KEY,           -- https://domain/items/<hex>
    owner_id        TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
    object_type     TEXT NOT NULL,              -- 'Note'|'Article'|'Document'|'Audio'|'Video'|'Image'
    name            TEXT,                       -- title; required for Article
    summary         TEXT,                       -- content-warning / abstract
    content         TEXT,                       -- HTML; NULL for pure-file items
    media_type      TEXT,                       -- 'application/pdf', 'audio/mpeg', …
    byte_size       INTEGER,                    -- bytes; NULL if unknown
    sha256          TEXT,                       -- hex
    rating          INTEGER,                    -- -3..3, NULL = unrated
    in_reply_to     TEXT,                       -- AP inReplyTo; reviews point at the reviewed item
    file_published  INTEGER NOT NULL DEFAULT 0, -- 0 = archived (encrypted remote only); 1 = published (public remote + url[])
    file_public_url TEXT,                       -- the minted download URL (uc?export=download form), NULL until published
    file_view_url   TEXT,                       -- the viewer mirror (open?id form), NULL until published; second listed url[] entry
    published_at    TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS item_owner_published ON item(owner_id, published_at DESC);
CREATE INDEX IF NOT EXISTS item_in_reply_to ON item(in_reply_to);
```

Changes from `sql/schema.sql` lines 58–76:

- **Removed:** the `privacy TEXT NOT NULL` column (line 62) and the `item_privacy_published` index (line 75). These do not appear in the fresh schema.
- **Added:** `file_published INTEGER NOT NULL DEFAULT 0`, `file_public_url TEXT`, `file_view_url TEXT`.

`file_public_url` is the **`uc?export=download` form** (the direct-download URL, the first `url[]` entry and the rendered download link). `file_view_url` is the **`open?id` viewer form** (the second listed `url[]` mirror). Both are derived from the same Google Drive file id (§3.3). Both are NULL while archived.

### 1.2 The `item_remote` table — unchanged in shape, repurposed in meaning

`item_remote` (schema lines 80–91) is **kept as-is**. It already holds (kind, target, media_type, label, published, sort_order) per mirror. Under the new model it records the two backend locations the daemon itself writes:

- one row, `kind='rclone'`, `target='<archive-remote>/<slug>'`, `published=0`, `label='archive (encrypted)'` — written on **every** upload;
- on publish-file, one more row, `kind='rclone'`, `target='<public-remote>/<slug>'`, `published=1`, `label='public download'`.

The user-supplied multi-mirror form (`remote_target`/`remote_kind`/`remote_label`) is **removed** from the upload UI (§5.1) — it was the wrong surface for a single-tenant site and its `RkGitAnnex`/`RkUrl`/`RkIpfs` plumbing is out of scope. `build-remotes`/`zip3-with-index`/`push-to-remote` in `src/web/handler/upload.kk` (lines 93–133) are deleted. The `item_remote` rows are now written by the upload/publish-file handlers directly (§3).

> The AP `url` array is **not** built from `item_remote` any more — it is built from `item.file_public_url` / `item.file_view_url` (§3.4, §4). `annex-item/published-remotes` (`src/annex/item.kk` lines 83–88) and the `published` flag's role in `item-to-ap-object` are superseded; see §6.

### 1.3 Migration — idempotent, applied by `init`/apply-schema

The schema-application path (`kk_aw_db_init_schema`, `csrc/db_bridge.c` line 309, run by `init` and by `serve`'s open) MUST, **after** running the `CREATE TABLE IF NOT EXISTS` schema, run an idempotent migration that adds `file_published`, `file_public_url`, `file_view_url` to any pre-existing `item` table that lacks them.

- The migration MUST be expressed so that re-running it is a no-op (an `ALTER TABLE item ADD COLUMN` on an existing column is an error in SQLite, so the migration MUST guard each add). The portable, `DROP COLUMN`-free, version-agnostic form is: read `PRAGMA table_info(item)`; for each of the three target columns, if absent, run `ALTER TABLE item ADD COLUMN …`. (`ADD COLUMN file_published INTEGER NOT NULL DEFAULT 0` is legal — the default backfills existing rows to "archived", which is the correct, safe default for any blob that was uploaded before the model existed.)
- The migration MUST **not** touch or reference `privacy`. A migrated DB keeps its dead `privacy` column; no `SELECT`/`INSERT`/`UPDATE`/`DELETE` in any `.kk` source names it after this change.
- The migration MUST run inside the same transaction/exec batch as the schema so `init` stays a single atomic command, and MUST be present **identically** in both schema sources' surrounding logic (the C bridge owns the column-existence probe; `sql/schema.sql` documents the fresh shape and carries the migration statements as commented reference so the two files stay reviewable side by side).

**Both schema sources MUST stay in sync** (the existing house rule, `csrc/db_bridge.c` line 230: "Edits MUST be mirrored to sql/schema.sql"). A reviewer diffing `sql/schema.sql` against the embedded string MUST see the same `item` columns in the same order.

---

## 2. Config: remote names + the public-URL test seam

### 2.1 Env-configurable remote names (`src/interp/config_env.kk`)

Two new config values, read once at handler-install time exactly like the existing six (`src/interp/config_env.kk` lines 15–20, via `env-or-default`):

| env var | default | meaning |
|---|---|---|
| `ANNEXWYRM_ARCHIVE_REMOTE` | `gdrive-crypt:annexwyrm` | rclone remote+prefix the upload always copies the blob to (the encrypted archive) |
| `ANNEXWYRM_PUBLIC_REMOTE`  | `gdrive:annexwyrm-public` | rclone remote+prefix publish-file additionally copies the blob to |
| `ANNEXWYRM_PUBLIC_URL_BASE` | `""` (empty ⇒ use `rclone link`) | **test seam** (§2.2): when non-empty, the public URL is constructed from this base instead of minted by `rclone link` |

The `config` effect (`src/effects/config.kk`) gains three matching operations:

```koka
fun get-archive-remote() : string      // ANNEXWYRM_ARCHIVE_REMOTE
fun get-public-remote()  : string      // ANNEXWYRM_PUBLIC_REMOTE
fun get-public-url-base() : string      // ANNEXWYRM_PUBLIC_URL_BASE ("" ⇒ rclone link)
```

`with-env-config` (`config_env.kk`) captures all three in closures alongside the existing six. No re-read per request (the module's documented contract).

The blob key within each remote is the item slug (`rand-hex(12)`, the last path segment of the item id), matching today's `Blob-loc("local", slug)` keying in `ingest` (`src/web/handler/upload.kk` line 77). So the archive location is `<archive-remote>/<slug>` and the public location is `<public-remote>/<slug>`.

### 2.2 The hermetic test seam for `blob-public-url`

`rclone link` (`src/interp/store_rclone.kk` `blob-public-url`, lines 30–35) returns Nothing for a **local** path — and the e2e suites point both remote env vars at **temp directories** (rclone treats a plain absolute path as the local backend), so `rclone link` cannot mint a URL there. The spec defines the seam:

- **`blob-public-url(loc)` MUST consult `get-public-url-base()` first.** When non-empty, it MUST return `Just(<base> ++ "/" ++ loc.key)` — a deterministic, constructed URL — **without** shelling out to `rclone link`. When empty, it MUST fall back to the existing `rclone link loc.show` behavior (the real gdrive path).
- This keeps the **pipeline** assertable hermetically: tests set `ANNEXWYRM_PUBLIC_URL_BASE=http://example.test/dl`, upload, publish-file, and assert the stored/rendered/federated URL is exactly `http://example.test/dl/<slug>` — without any gdrive credentials or network.
- The **real** `rclone link` path (the gdrive viewer URL, and the `uc?export=download` derivation from its file id) is asserted only in the gdrive-gated variant behind `ANNEXWYRM_E2E_GDRIVE=1` (§7, run.sh delta), exactly as the existing suite already gates its real-gdrive listing assertion (`run.sh` lines 263–265, `USE_GDRIVE`).

> Because the constructed-URL seam yields a single URL, the `uc?export=download` vs `open?id` distinction (§3.3) is a **gdrive-only** concern. In the hermetic path `file_public_url == file_view_url == <base>/<slug>` is acceptable and MUST be asserted as such; the two-form derivation is asserted only under `ANNEXWYRM_E2E_GDRIVE=1`.

---

## 3. The upload pipeline

`handle-upload-post` → `ingest` (`src/web/handler/upload.kk` lines 29–95) is rewritten. The new form fields (§5.1) are: `file`, `name`, `summary`, `content`, `rating`, `in_reply_to`, and `publish_file` (a checkbox; present ⇒ publish now, absent ⇒ archive only). The `privacy` field and all `remote_*` fields are **gone**.

### 3.1 Sequence (v1 is synchronous)

On a valid multipart POST from the owner session:

1. Compute `slug = rand-hex(12)`, `id = base-url ++ "/items/" ++ slug`, `media`, `sha`, `byte-size` as today (lines 66–72).
2. **Mandatory archive put.** `blob-put(Blob-loc(get-archive-remote(), slug), f.body)`. **If this fails, the upload FAILS LOUDLY** — see §3.2.
3. Record one `item_remote` row for the archive location (`kind='rclone'`, `target=<archive-remote>/<slug>`, `published=0`, `label='archive (encrypted)'`).
4. Construct the `annex-item` value (no `privacy` field; `file_published=0`, `file_public_url=""`, `file_view_url=""`), `save-item` it.
5. **`emit-create(item)`** — the review federates immediately. (This is new in the upload path; §6.)
6. **If `publish_file` is set**, run the publish-file body (§4.3) inline, before redirecting: copy to the public remote, mint the URL, set `file_published=1` + the two URLs, `save-item`, and **`emit-update`** (not a second `Create`).
7. `info("upload/done", [("id", id), ("size", byte-size.show), ("file_published", (if published then "1" else "0"))])`.
8. `see-other("/items/" ++ slug)`.

> Note the `upload/done` log line shape **changes**: the old `("remotes", rs.length.show)` field (line 94) is replaced by `("file_published", "0"|"1")`. The federation suite's current assertion `… remotes=0` (SPEC-federation.md F4) MUST become `… file_published=0` (or `=1`); see §7.

### 3.2 Failure semantics — mandatory archive put

A review whose file evaporated is worse than a failed upload.

- If the archive `blob-put` raises (rclone non-zero exit), `ingest` MUST return a **5xx** response (`server-error`, the 500 surface in `src/web/server.kk`) whose body names the failure, and MUST log the rclone error to the daemon stderr log at `error`/`warn`. The item row MUST **NOT** be saved and **NO** `Create` MUST be emitted — a failed archive put yields no item and no federation. (Order: archive put happens *before* `save-item`/`emit-create` precisely so a put failure aborts the whole upload.)
- The `store` effect (`src/effects/store.kk`) currently models `blob-put` as `() ` with no failure channel; the rclone interpreter (`store_rclone.kk` lines 14–16) discards `run`'s result. To make "fails loudly" real, **the upload handler MUST verify the put landed** — the simplest assertable contract is: after the archive `blob-put`, call `blob-has(Blob-loc(get-archive-remote(), slug))` and, if false, take the 5xx path above. (This keeps the `store` effect's signature untouched, stays portable, and is directly testable in the hermetic suite by pointing the archive remote at an unwritable path — §7 forbids-if-it-didn't-crash control.)
- v1 is **synchronous**: the HTTP response is not returned until the archive put (and, if requested, the public put + link mint) have completed or failed. No background queue.

### 3.3 The minted public URL forms (gdrive)

When publishing the file to the **real** gdrive public remote, `rclone link <public-remote>/<slug>` returns a viewer URL of the form `https://drive.google.com/open?id=<ID>`. The handler MUST:

- store that viewer URL as `file_view_url` (the `open?id` form, kept as a second listed mirror);
- derive `file_public_url` as `https://drive.google.com/uc?export=download&id=<ID>` by extracting `<ID>` from the `open?id=<ID>` URL — this direct-download form is the primary `url[]` entry and the rendered download link.

In the **hermetic** path (`ANNEXWYRM_PUBLIC_URL_BASE` set), `blob-public-url` returns the single constructed URL and `file_public_url == file_view_url == <base>/<slug>` (§2.2).

### 3.4 What goes in the federated object

`item-to-ap-object` (`src/annex/publish.kk` lines 19–38) is changed so `urls` is built **from the item's file-publication state**, not from `item_remote.published`:

- when `file_published = 0`: `urls = []` (the `url` field is omitted by the encoder — `urls-json` already returns `JNull` for an empty list, `src/ap/object.kk` lines 143–148). **Nothing about the blob appears in the federated object.**
- when `file_published = 1`: `urls = [Ap-link(file_public_url, media-type, "download", ""), Ap-link(file_view_url, media-type, "view", "")]` — the `uc?export=download` form first, the `open?id` viewer second. (In the hermetic single-URL case the second entry equals the first; the encoder MAY emit one or two — the test asserts the `download` link is present and equals `file_public_url`.)

The addressing helper input changes: there is no per-item privacy any more. Every item is public, so `item-to-ap-object` MUST address it as public — `build-addressing(ItPublic, followers-url, [])` (`src/ap/addressing.kk` line 39 → `to=[Public], cc=[followers]`). The `privacy` argument disappears from the item; `ItPublic` is passed as the fixed audience. See §6 for the `privacy`-type disposition.

---

## 4. The publish-file-later journey

### 4.1 Route

`src/web/route.kk` lines 77–82 change:

- **Remove** `POST /items/<id>/publish` (→ `handle-item-publish`), `POST /items/<id>/unpublish` (→ `handle-item-unpublish`), and `POST /items/<id>/update` (→ `handle-item-update`). All three privacy-era handlers go.
- **Add** `POST /items/<id>/publish-file` (→ `handle-item-publish-file`).

The matcher: `("POST", Cons("items", Cons(id, Cons("publish-file", Nil)))) -> handle-item-publish-file(req, id)`.

### 4.2 Handler

`handle-item-publish-file(req, id)` replaces `handle-item-publish` (`src/web/handler/item.kk` lines 36–50). Effect row gains `store` (it shells out via the blob effect): `<db,time,rng,log,config,store,div|e>`.

- Owner-gated: `if !is-owner-session(req) then forbidden("login required")` (unchanged gate).
- Load the item; `not-found("no such item")` if absent.
- **Idempotency:** if `item.file_published == 1` already, do **not** re-copy or re-emit; `see-other("/items/" ++ id)` immediately. (One-way for v1; re-posting publish-file is a harmless no-op, not a double `Update`.)
- Otherwise run the publish-file body (§4.3), then `see-other("/items/" ++ id)`.

### 4.3 The publish-file body (shared by upload-with-`publish_file` and the later action)

Per koka#654: pure `build-*` constructs value structs; effectful `ship-*`/handlers take them as parameters; `emit-*` returns `()` (see `src/ap/outbox.kk`). The publish-file body is effectful and ends in `emit-update`, which already returns `()` (outbox.kk lines 81–84). Steps:

1. **Mandatory public put.** `blob-put(Blob-loc(get-public-remote(), slug), bytes)`. The bytes come from `blob-get(Blob-loc(get-archive-remote(), slug))` for the later action (the original upload bytes are not in memory then), or directly from `f.body` in the upload-inline case. If the public put fails (`blob-has` check, mirroring §3.2), the action MUST return **5xx** and MUST NOT flip `file_published`, mint a URL, or emit any activity — the file stays archived. The archive copy is never touched by publish-file.
2. **Mint the URL.** `match blob-public-url(Blob-loc(get-public-remote(), slug))`: on `Nothing`, 5xx (the link could not be produced — a failed publish, not a silent archived-state); on `Just(view)`, derive `file_public_url`/`file_view_url` per §3.3.
3. Record the public `item_remote` row (`kind='rclone'`, `target=<public-remote>/<slug>`, `published=1`, `label='public download'`).
4. Build the updated item: `file_published=1`, the two URLs set, `updated_at = now`. `save-item`.
5. **`emit-update(item)`** — outbox.kk `emit-update` (lines 81–84) builds an `Update` wrapping `item-to-ap-object`, which now carries the `url` array (§3.4). One `Update` activity row is written (`inbox_remote=0`), and one delivery per accepted follower is queued (zero on a no-follower instance — same invariant as SPEC-publish.md §4).

### 4.4 AP `Update`, addressing, and the `url` array

- The activity is an **`Update`** (AS2 type), `actor = item.owner`, `object = item-to-ap-object(item, followers)` with the populated `urls` (§3.4). It is **not** a second `Create` and **not** a `Delete`.
- Addressing: `to=[Public], cc=[followers]` (public item). Delivery fans out to **accepted followers only** (`resolve-recipients` → `followers-inboxes`, `src/ap/outbox.kk` lines 31–39), so a single-actor instance queues **zero** deliveries and logs `recipients=0`; a one-follower instance queues one and logs `recipients=1`.
- The `url` array contents (published case): the `uc?export=download` direct-download URL first, the `open?id` viewer URL second (hermetic: a single constructed URL). The `download` link's `href` MUST equal `file_public_url`.

---

## 5. UI — NO-JS, server-rendered

### 5.1 Upload form (`src/web/html/upload.kk`)

- **Delete** the `privacy` `<select>` (lines 22–29).
- **Delete** the entire "mirrors" fieldset and the `remote-row` helper (lines 48–72) — the multi-mirror UI is gone.
- **Add**, in the file fieldset, a checkbox: `<label><input type="checkbox" name="publish_file" value="1"> publish file now (default: archive only, no public download)</label>`. **Default OFF** (no `checked`). The hint text MUST state that, unchecked, the file goes only to the encrypted archive and no download link is published; checked, it is also copied to the public remote and a download link is minted and federated.
- Keep `name`, `summary` (relabeled "content warning / abstract"), `content` (the review body), `rating`, `in_reply_to`. The form remains `enctype="multipart/form-data"`, no JavaScript.

### 5.2 Item page (`src/web/html/item.kk`) — archived vs published states

- **Delete** the `<span class="privacy">…</span>` meta (line 23) — there is no per-item privacy to show.
- **Delete** `actions-block`'s publish/unpublish forms (lines 80–94) and `remotes-block`'s mirror list driven by `item_remote.published` (lines 61–78) in their privacy-era form.
- **Add a file-state block** with exactly two server-rendered states, owner-gated for the action:

  - **Archived (`file_published = 0`):** render a quiet, no-link state — literal text `file archived, not published` inside `<p class="file-state archived">`. **No download anchor.** If the viewer is the owner (`is-owner-session`), additionally render the publish-file action form:
    ```html
    <form action="/items/<slug>/publish-file" method="post">
      <button type="submit">publish file</button>
    </form>
    ```
    To a non-owner anonymous visitor, render only the `file archived, not published` line and **no** form.

  - **Published (`file_published = 1`):** render the download link from `file_public_url` inside `<p class="file-state published">`:
    ```html
    <a class="download" href="<file_public_url>" rel="nofollow">download</a>
    ```
    and (optionally) the viewer mirror from `file_view_url`. **No** publish-file form (one-way; nothing to do). The same published state is shown to everyone — the file is public.

- The page MUST otherwise render the full review (title, rating badge + stars, review-of preamble, content/body) to **all** visitors. There is no owner-only item view and no 404-for-private branch (§6).

### 5.3 Home list (`src/web/html/home.kk`, `src/web/handler/home.kk`)

- The home query (`src/web/handler/home.kk` lines 18–25) currently filters `WHERE privacy IN ('public','unlisted')` (line 22). **Remove the WHERE clause** — every item is public, so the home list shows **all** items: `SELECT id, name, object_type, COALESCE(rating,99), COALESCE(in_reply_to,''), published_at FROM item ORDER BY published_at DESC LIMIT 50`. The `privacy` column is dropped from the `SELECT`.
- `home-row` (`src/web/html/home.kk` lines 9–17) loses its `privacy` field; `item-row` (lines 34–43) stops rendering `· <privacy>` in the meta line. It MAY render a small `[file]` marker when `file_published=1` (so the index hints which items have a download), but MUST NOT show any privacy word.

---

## 6. Every privacy touchpoint — named, file:line, with its disposition

| # | Touchpoint | File:line | Disposition |
|---|---|---|---|
| 1 | upload `privacy` form field parse | `src/web/handler/upload.kk:44–45` | **Delete.** No `privacy` parsed; item has no privacy. |
| 2 | upload `remote_*` fields + `build-remotes`/`zip3-with-index`/`push-to-remote` | `src/web/handler/upload.kk:48–52,80,93,98–133` | **Delete.** Multi-mirror UI removed; archive/public `item_remote` rows written by the handler (§3). |
| 3 | upload `privacy` arg threaded into `Annex-item` | `src/web/handler/upload.kk:51,59,81–88` | **Replace** with `file_published`/URL fields; emit `Create` after save (§3.1). |
| 4 | `handle-item` 404-for-private authz branch | `src/web/handler/item.kk:25–26` | **Delete.** Items are always public; anonymous GET always renders (or 404s only if truly absent). No `is-owner-session` gate on read. |
| 5 | `load-item` reads `privacy` column + parses it | `src/web/handler/item.kk:83,99` | **Remove** `privacy` from the SELECT and from `Annex-item` construction; read `file_published`, `file_public_url`, `file_view_url` instead. |
| 6 | `save-item` writes `privacy` column | `src/web/handler/item.kk:131,135` | **Remove** `privacy` from the INSERT; write `file_published`, `file_public_url`, `file_view_url`. |
| 7 | `handle-item-publish` (privacy flip + `emit-create`) | `src/web/handler/item.kk:36–50` | **Delete handler;** replace route with `handle-item-publish-file` (§4). |
| 8 | `handle-item-unpublish` (privacy flip + `emit-delete`) | `src/web/handler/item.kk:52–64` | **Delete handler and route.** No unpublish in v1 (§0, §8). |
| 9 | `handle-item-update` | `src/web/handler/item.kk:66–75` | **Delete handler and route.** `Update` is now emitted only by publish-file. |
| 10 | publish/unpublish/update route matchers | `src/web/route.kk:77–82` | **Replace** with the single `publish-file` matcher (§4.1). |
| 11 | `annex-item.privacy` field | `src/annex/item.kk:32` | **Remove** field; **add** `file-published : bool`, `file-public-url : string`, `file-view-url : string` to the value struct. Update `fresh-item` (lines 90–116) accordingly (drop the `privacy = ItPrivate` line). |
| 12 | `annex-item/is-federated` (reads `privacy.federates`) | `src/annex/item.kk:78–80` | **Delete or hardcode `True`** — every item federates. Remove callers' dependence on it. |
| 13 | `item-remote.published` driving `url[]` via `published-remotes` | `src/annex/item.kk:83–88`; `src/annex/publish.kk:29` | **Repurpose:** `item-to-ap-object.urls` is built from `file_public_url`/`file_view_url` (§3.4), not `published-remotes`. `published-remotes` MAY be deleted. |
| 14 | `item-to-ap-object` privacy → addressing | `src/annex/publish.kk:20` | **Replace** `build-addressing(i.privacy, …)` with `build-addressing(ItPublic, …)` (always public). |
| 15 | `publish-item` / `unpublish-item` (privacy transitions) | `src/annex/publish.kk:46–81` | **Delete.** Replaced by the publish-file body (§4.3) which flips `file_published`, not privacy. |
| 16 | home WHERE clause `privacy IN ('public','unlisted')` | `src/web/handler/home.kk:22` | **Delete the WHERE.** Show all items (§5.3). |
| 17 | `home-row.privacy` + rendering | `src/web/html/home.kk:13,42` | **Remove** the field and its `· <privacy>` render. |
| 18 | item-page `<span class="privacy">` | `src/web/html/item.kk:23` | **Delete** (§5.2). |
| 19 | item-page `actions-block` publish/unpublish forms | `src/web/html/item.kk:80–94` | **Replace** with the file-state block (§5.2). |
| 20 | upload-form `privacy` select + mirrors fieldset | `src/web/html/upload.kk:22–29,48–72` | **Replace** with the `publish_file` checkbox (§5.1). |
| 21 | `item` table `privacy` column + `item_privacy_published` index | `sql/schema.sql:62,75`; `csrc/db_bridge.c:257,263` | **Drop from fresh schema; keep-dead on migrated DBs** (§1.1). Add `file_published`/`file_public_url`/`file_view_url` (§1.1, §1.3). |
| 22 | `privacy` type (`ItPrivate`/`ItUnlisted`/`ItFollowers`/`ItPublic`) + `federates`/`is-public` | `src/core/types.kk:127–157` | **Keep the type** — `ItPublic` is still used as the fixed audience passed to `build-addressing`, and `infer-visibility` (`src/ap/addressing.kk:26–31`) still classifies *incoming* federated activities. The type is no longer a *property of a local item*; it survives only as an addressing/visibility classifier for AP. Do not delete it. |

Federation addressing (the `to`/`cc` an item federates with) is now **always** `to=[Public], cc=[followers]` (§3.4, touchpoint 14). The follower fan-out logic (`resolve-recipients`, `followers-inboxes`) is unchanged: it already keys on `state='accepted'` follow rows, so the zero/one-delivery invariants from SPEC-publish.md and SPEC-federation.md still hold — only the activity type (`Update` on publish-file vs the old `Create` on privacy-publish) and the upload-side `Create` change.

---

## 7. The e2e DELTA — per suite

Every NEW step asserts the **(a) screen / (b) daemon log / (c) DB** triple. Forbid-if-it-didn't-crash applies to every step. All three suites MUST stay green: `run.sh`, `run-caddy.sh`, `run-federation.sh`.

### 7.1 Hermetic seam, used by all three suites

Every suite that uploads MUST export, alongside its existing identity env:

```
ANNEXWYRM_ARCHIVE_REMOTE="$TMP/archive"     # local backend ⇒ real bytes land in a temp dir
ANNEXWYRM_PUBLIC_REMOTE="$TMP/public"       # local backend
ANNEXWYRM_PUBLIC_URL_BASE="http://example.test/dl"   # the blob-public-url seam (§2.2)
```

and `mkdir -p "$TMP/archive" "$TMP/public"`. The **gdrive-gated** variant (behind `ANNEXWYRM_E2E_GDRIVE=1`, mirroring `run.sh`'s existing `USE_GDRIVE`) instead points the two remotes at `gdrive-crypt:annexwyrm-test` / `gdrive:annexwyrm-public-test`, **unsets** `ANNEXWYRM_PUBLIC_URL_BASE` (so the real `rclone link` path runs), and asserts the real `uc?export=download` / `open?id` URL shapes and encrypted-at-rest semantics; the hermetic path asserts only the pipeline.

### 7.2 `tests/e2e/run.sh` (currently 61 asserts) — delta

The suite is **saturated with privacy semantics that this change invalidates** (the publish/unpublish federation journey, the `privacy=public`/`privacy=private` uploads, the 404-for-private assertions). The `upload`/`post_action` helper signatures in `lib.sh` change.

**Helper changes (`lib.sh`):** the `upload` helper (lib.sh lines 118–139) **drops** the `privacy` positional arg (was `$7`) and the `remote_*` args (`$10`–`$12`), and **adds** an optional `publish_file` arg. New shape: `upload SOCK JAR FILE TITLE SUMMARY CONTENT RATING IN_REPLY_TO [PUBLISH_FILE]`; it emits `--form-string "rating=…"`, `--form-string "in_reply_to=…"`, and, when `PUBLISH_FILE=1`, `--form-string "publish_file=1"`. No `privacy=` field is ever sent. (`upload_tcp` in lib.sh lines 317+ gets the same edit.)

**Assertions that DIE (remove):**

- Every `privacy=public` / `privacy=private` upload arg, and every `SELECT privacy FROM item …` / `WHERE privacy=…` assertion (run.sh lines 179, 197, 291–292, 345–346, and the whole publish/unpublish DB-delta block 282–487 that asserts `privacy` transitions).
- The "private PDF is 404 to anon" assertion (run.sh line 251+, `assert_status … 404` for the private item) — **dies**; there are no private items. The private-content-leak negative checks tied to it die with it.
- The entire **PUBLISH / UNPUBLISH** journey (run.sh ~282–487: P0–P3, U1–U3, the `unpublish` Delete activity, the owner-only-view re-fetch, the `/publish`/`/unpublish` form-presence assertions). The `outbox/publish … type=Create` and `outbox/delete` log assertions die; the `actions-block` `/publish`/`/unpublish` HTML assertions die.

**Assertions that CHANGE:**

- The two PDF uploads become "archived PDF" (no `publish_file`) and (optionally) "published PDF" (`publish_file=1`). The `upload/done` log assertion changes from `… remotes=0` to `… file_published=0` (archived) / `… file_published=1` (published-on-upload).
- The home-list assertion stops expecting `· public`/filtering by privacy; it now expects **all** uploaded items to appear (the WHERE removal, §5.3).
- The anonymous item-page fetch asserts the **review renders to anon** for every item (no 404-for-private), and asserts the file-state markers below.

**Assertions that are NEW** (each with the (a)/(b)/(c) triple):

- **Step A — upload archived (default).** `upload "$SOCK" "$JAR" "$PDF" "Archived PDF" "" "<p>secret research; key results below.</p>" "99" ""` (no `publish_file`).
  - **(a)** `303`, `Location` `^/items/[0-9a-f]+$` → capture `ARCH_PATH`/`ARCH_URL`. Anon `GET $ARCH_PATH` → `200`; body contains the review body `secret research; key results below.` AND `file archived, not published` AND has **no** `class="download"` anchor.
  - **(b)** `^\[info\] upload/done id=$ARCH_URL size=[0-9]+ file_published=0$`. AND a `Create` emission: `^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Create recipients=0` (upload now federates the review; `recipients=0` on the no-follower instance).
  - **(c)** `SELECT file_published FROM item WHERE id='$ARCH_URL';` == `0`. `SELECT file_public_url IS NULL OR file_public_url='' FROM item WHERE id='$ARCH_URL';` == `1`. Exactly one `Create` activity for the item: `SELECT count(*) FROM activity WHERE type='Create' AND object_id='$ARCH_URL';` == `1`. **Real bytes landed in the archive temp dir:** `[ -f "$TMP/archive/<slug>" ]` AND `cmp -s "$TMP/archive/<slug>" "$PDF"` (the encrypted-at-rest variant asserts the bytes are *not* equal to the plaintext under `ANNEXWYRM_E2E_GDRIVE=1`). **No** byte in the public temp dir: `[ -z "$(ls -A "$TMP/public")" ]`.
- **Step B — publish-file later.** `post_action "$SOCK" "$JAR" "$ARCH_PATH/publish-file"`.
  - **(a)** `303`, `Location` == `$ARCH_PATH`. Anon `GET $ARCH_PATH` → `200`; body now contains `<a class="download" href="http://example.test/dl/<slug>"` AND no longer contains `file archived, not published`.
  - **(b)** `^\[info\] outbox/publish id=http://localhost/activities/[0-9a-f]+ type=Update recipients=0` (publish-file emits **`Update`**, not `Create`; `recipients=0`). (Reuse the publish log label `outbox/publish` from `ship-activity`; the discriminator is `type=Update`.)
  - **(c)** `SELECT file_published FROM item WHERE id='$ARCH_URL';` == `1`. `SELECT file_public_url FROM item WHERE id='$ARCH_URL';` == `http://example.test/dl/<slug>`. Exactly one `Update`: `SELECT count(*) FROM activity WHERE type='Update' AND object_id='$ARCH_URL';` == `1`, `inbox_remote=0`, `actor_id='$ACTOR_URL'`, and its `raw` contains the download URL: `SELECT raw LIKE '%http://example.test/dl/%' FROM activity WHERE type='Update' AND object_id='$ARCH_URL';` == `1`. Delivery delta `== 0` (no followers). **Bytes now in the public temp dir:** `[ -f "$TMP/public/<slug>" ]`. The `Create` from Step A still exists (publish-file does not retract it): both `Create` and `Update` present.
- **Step C — publish-file idempotency.** `post_action … "$ARCH_PATH/publish-file"` a second time → `303`; **(c)** still exactly one `Update` for the item (no second `Update` row), `file_published` still `1`, delivery total unchanged.
- **Step D — owner gate.** Anonymous `POST $ARCH_PATH/publish-file` (no jar) → `403` + body `login required`; **(c)** no new activity rows. (This is the renamed survivor of the old §5 auth-edge step.)
- **Step E — archive-put failure (forbid-if-it-didn't-crash control).** With `ANNEXWYRM_ARCHIVE_REMOTE` pointed at an unwritable path (e.g. a file, not a dir, or a `chmod 000` dir), attempt an upload → **(a)** `5xx`; **(b)** an `error`/`warn` log line carrying the rclone failure; **(c)** `SELECT count(*) FROM item WHERE name='Doomed';` == `0` AND `SELECT count(*) FROM activity WHERE object_id LIKE '%';`-delta `== 0` for that upload (no item, no `Create`). This step proves the mandatory-archive-put 5xx contract (§3.2) is real and not a swallowed error.

### 7.3 `tests/e2e/run-caddy.sh` (currently 110 asserts) — delta

This suite is the "real human sees a styled working archive" gate; its privacy assertions invalidate.

**Assertions that DIE:**
- The `privacy=public` / `privacy=private` upload args (Steps 8–9) and the `SELECT privacy FROM item …` assertions (SPEC-caddy.md Step 8c, 9c).
- **Step 15** "private to anon → 404" in its entirety (SPEC-caddy.md §3 Step 15): there are no private items, so the `assert_status_tcp "$PRIVATE_PATH" 404` and the private-leak negative checks die.

**Assertions that CHANGE:**
- Steps 8–11 uploads drop `privacy=`; the "private PDF" upload becomes an **archived** PDF (no `publish_file`), the "public PDF" becomes either archived or `publish_file=1`. Their `upload/done` log assertions change to `file_published=0|1` (SPEC-caddy.md Step 8b/9b's `remotes=0` → `file_published=…`).
- Step 13 home-list assertion: no `· public` privacy word; assert all uploaded items appear (WHERE removed). The `[review]` marker assertion is unchanged.
- Step 15 becomes "**anonymous browsing sees every item (200)**" — the formerly-private item is now `200` to anon (it is a public review with an archived file), and its page shows `file archived, not published` with **no** download link. Assert `assert_status_tcp "$ARCH_PATH" 200` and `assert_grep` for `file archived, not published` and the absence of `class="download"`.

**Assertions that are NEW** (Caddy-fronted, so they also re-prove `Via: 1.1 Caddy` on the proxied path):
- **Caddy Step N1 — publish-file through Caddy.** `POST $ITEM_PATH/publish-file` via the TCP helper with the session jar, no `-L` → `303`, `Location: $ITEM_PATH`, `Via: 1.1 Caddy`. **(b)** `outbox/publish … type=Update`. **(c)** `file_published=1`, `file_public_url='http://example.test/dl/<slug>'`, public temp-dir byte present.
- **Caddy Step N2 — published item page through Caddy renders the download link.** Anon `GET $ITEM_PATH` → `200`, `text/html; charset=utf-8`, body contains `<a class="download" href="http://example.test/dl/` and the review body; `Via` present.
- **Caddy Step N3 — archived item page through Caddy.** Anon `GET $ARCH_PATH` → `200`, body contains `file archived, not published`, no `class="download"`, `Via` present.

### 7.4 `tests/e2e/run-federation.sh` (currently 107 asserts) — delta

The federation handshake (F1–F3, follow → auto-accept → accept) is **unaffected** — it does not touch item privacy.

**Assertions that CHANGE (F4–F5, the publish + delivery climax):**
- **F4 upload log** (SPEC-federation.md F4(b), Appendix A): `^\[info\] upload/done id=$B_BASE/items/[0-9a-f]+ size=[0-9]+ remotes=0` → `… file_published=0` (B uploads archived). Because **upload now emits `Create`**, F4 MUST add: `^\[info\] outbox/publish id=…/activities/[0-9a-f]+ type=Create recipients=1` **at upload time** (B's only accepted follower is A) — this `Create` fans out to A. The old model emitted the `Create` from the separate `POST /publish`; the new model emits it from the upload. The upload's `recipients=1` is the new headline that proves the handshake mattered.
- **The publish step is no longer `POST /items/<id>/publish`** (that route is deleted). To exercise the blob-publication `Update` over the wire, F4 gains a **publish-file** step: `POST $B_BASE$ITEM_PATH/publish-file` (jar, empty body, no `-L`) → `303`. **(b/B)** `^\[info\] outbox/publish id=…/activities/[0-9a-f]+ type=Update recipients=1`. **(c/B)** one `Update` activity (`inbox_remote=0`) whose `raw` contains the public URL; one delivery queued to `$A_INBOX`, pending.
- **F5 drain** delivers **both** the upload-time `Create` and the publish-file `Update` (two pending rows now). The receiver (A) MUST end with **both** activities recorded inbound (`inbox_remote=1`): `SELECT count(*) FROM activity WHERE id='$CREATE_AID' AND inbox_remote=1;` == `1` AND `SELECT count(*) FROM activity WHERE type='Update' AND object_id='$ITEM_URL' AND inbox_remote=1;` == `1`. A's stored `Update` raw MUST contain the download URL (`raw LIKE '%uc?export=download%'` in the gdrive variant, or `%http://example.test/dl/%` hermetic). As before, A stores **no** `item` row for B's object (FINDING 9 unchanged): `SELECT count(*) FROM item WHERE id='$ITEM_URL';` == `0` on A_DB.

**Assertions that are NEW:**
- **F-archive invariant.** After F4's upload (archived), B's public temp dir is **empty** for that slug and B's archive temp dir holds the bytes — asserted on B's filesystem. After the publish-file step, the public temp dir holds the slug. This proves, over the federated path, that an archived blob never reaches the public remote until publish-file.
- **The Drive `drain` Tier-1/Tier-0 split** (SPEC-federation.md §0) is unchanged in mechanism; the only delta is that there are now two deliverables (Create + Update) instead of one, so the Tier-1 drain MUST report draining **2** across the two drains, and Tier-0 replays both signed POSTs.

### 7.5 Forbid-if-it-didn't-crash (every new step)

No new step may pass on exit-code alone. Each asserts at least one of: an exact HTTP status, a literal HTML substring (download anchor / `file archived, not published`), an exact SQL scalar (`file_published`, `file_public_url`, activity count/type, delivery count), an exact daemon-log line shape (`upload/done … file_published=…`, `outbox/publish … type=Create|Update recipients=N`), or exact bytes on disk (`cmp`/`[ -f ]` against the temp-dir backend). The archive-put-failure control (run.sh Step E) and the unsigned/dedup controls (federation F6) are mandatory teeth.

---

## 8. v1 scope decision: publish-file is one-way

The owner asked: ship unpublish-file only if this spec finds it trivial. **It is not trivial.** Unpublish-file would require, atomically and reversibly: `blob-del(Blob-loc(get-public-remote(), slug))` (deletes from the public remote — a destructive op with no archive fallback if it half-fails), clearing `file_public_url`/`file_view_url`, flipping `file_published` back to `0`, deleting the public `item_remote` row, and emitting an **`Update` that *shrinks* the `url` array** (an unusual federated signal many servers handle inconsistently). Each of those has a failure mode the archived→published direction does not. v1 therefore ships **publish-file only** (one-way). A later spec MAY add `POST /items/<id>/unpublish-file` with the deletion + shrinking-`Update` semantics fully specified.

---

## 9. Build / portability invariants (house rules — violating any is a regression)

- **koka#654:** pure `build-*` (config-only) constructs value structs; effectful `ship-*`/handlers take them as parameters; `emit-*` returns `()`. The publish-file body ends in `emit-update`, which already obeys this (`src/ap/outbox.kk` lines 81–94). Any new builder MUST follow the `ap/outbox.kk` pattern.
- **Linux portability:** NO C identifier named `unix` (gcc predefines it `=1`); the C bridge header is `csrc/aw_bridge.h` and MUST never be named after a koka module. The migration's `PRAGMA table_info` probe lives in `csrc/db_bridge.c` and MUST compile clean on darwin (`nix build .#default`) AND Ubuntu (koka 3.2.3 + gcc, `/opt/annexwyrm`).
- **Canonical darwin build:** `nix build .#default` (dev-shell `just build` is broken on this host). Any NEW file (including this spec, the rewritten suites) MUST be `git add`ed or nix cannot see it.
- **Daemon logs to stderr** (`src/interp/log_console.kk`); the suites grep `$LOG`, not stdout, and match lowercase `[info]`/`[warn]`/`[error]` (never `[INFO]`).
- **macOS BSD test-shell rules:** `grep -i` for headers (never `awk` IGNORECASE), `--form-string` for literal multipart fields, `-F file=@…;type=…` only for the file, bounded poll loops (no foreground `sleep`).
- **Schema in two places:** `sql/schema.sql` AND the embedded `ANNEXWYRM_SCHEMA` in `csrc/db_bridge.c` MUST stay byte-coherent (same `item` columns, same order). The migration logic lives in the C bridge; `sql/schema.sql` documents it.
- **Do NOT commit or push.** The supervisor verifies, commits, deploys.

---

## 10. Definition of done

The model is correctly landed **iff**:

1. A fresh `init` produces an `item` table with `file_published`/`file_public_url`/`file_view_url` and **no** `privacy` column; a DB carried over from the old schema gains the three columns idempotently and keeps a dead `privacy` column. Re-running `init` is a no-op.
2. No `.kk` source reads or writes the `item.privacy` column; the `privacy` *type* survives only as the AP audience/visibility classifier (touchpoint 22).
3. Upload always copies the blob to the archive remote, always emits `Create`, and fails 5xx (no item, no `Create`) if the archive put cannot be verified.
4. `POST /items/<id>/publish-file` copies to the public remote, mints + stores the download URL, adds it to the AP `url` array, and emits `Update`; it is owner-gated, idempotent, and one-way.
5. The archived item page shows the full review and `file archived, not published` with no download link; the published item page shows the download link; both render to anonymous visitors (no 404-for-private).
6. All three suites are green with the deltas in §7, the hermetic seam asserts real bytes in temp dirs and the constructed public URL, and the gated `ANNEXWYRM_E2E_GDRIVE=1` variant asserts the real encrypted-at-rest archive and the `uc?export=download` / `open?id` URL forms.

The model has **earned its place** only if these deliberate sabotages turn the suites red:

- **Skip the upload `emit-create`** → run.sh Step A(b) `outbox/publish … type=Create` and (c) Create-count fail; federation F4 `recipients=1` Create fails.
- **Make the archive put non-mandatory** (swallow the rclone failure, save the item anyway) → run.sh Step E's `5xx` + no-item assertions fail.
- **Leak the blob URL while archived** (populate `url[]` for `file_published=0`) → run.sh Step A's "no `class="download"`" and the AP-object `url`-empty assertion fail.
- **Emit `Create` instead of `Update` on publish-file** → run.sh Step B(b) `type=Update` and the one-`Update`-row SQL fail.
- **Re-introduce the 404-for-private branch** → run.sh/run-caddy.sh "every item renders to anon `200`" fail.
- **Restore the home `WHERE privacy …` clause** → the "all items appear on home" assertion fails.
- **Read or write `item.privacy`** anywhere → a fresh-`init` DB has no such column and the daemon errors at that query (the suite's first upload/render against a fresh DB fails loudly).

If any sabotage does not turn the suites red, the model does not meet this spec.

---

## Appendix A — exact strings the suites assert (copy targets)

| Where | Literal / pattern |
|---|---|
| Upload log (archived) | `^\[info\] upload/done id=<item-url> size=[0-9]+ file_published=0$` |
| Upload log (published-on-upload) | `^\[info\] upload/done id=<item-url> size=[0-9]+ file_published=1$` |
| Upload Create emission | `^\[info\] outbox/publish id=<base>/activities/[0-9a-f]+ type=Create recipients=<N>` |
| Publish-file Update emission | `^\[info\] outbox/publish id=<base>/activities/[0-9a-f]+ type=Update recipients=<N>` |
| Archived item page | `file archived, not published` inside `<p class="file-state archived">`; NO `class="download"` |
| Published item page | `<a class="download" href="<file_public_url>"` inside `<p class="file-state published">` |
| Publish-file action (owner, archived) | `action="/items/<slug>/publish-file" method="post"` |
| Publish-file redirect | `303` + `Location: /items/<slug>` |
| Hermetic public URL | `http://example.test/dl/<slug>` (== `file_public_url` == `file_view_url`) |
| gdrive public URL (gated) | `file_public_url` == `https://drive.google.com/uc?export=download&id=<ID>`; `file_view_url` == `https://drive.google.com/open?id=<ID>` |
| Archive bytes (hermetic) | `[ -f "$TMP/archive/<slug>" ]`, `cmp -s` == plaintext |
| Archive bytes (gdrive gated) | bytes NOT equal to plaintext (encrypted-at-rest) |
| Public bytes appear only after publish-file | `[ -z "$(ls -A "$TMP/public")" ]` before; `[ -f "$TMP/public/<slug>" ]` after |
| Owner gate | `403` + `login required` |
| Archive-put failure | `5xx` + an `[error]`/`[warn]` rclone line; zero item rows, zero Create |

## Appendix B — grounding map (why each requirement is real, not guessed)

| Requirement | Source of truth |
|---|---|
| upload emits nothing today; publish emits Create | `src/web/handler/upload.kk` `ingest` (no `emit-*`); `src/web/handler/item.kk:36–50` |
| `blob-put`/`blob-get`/`blob-has`/`blob-public-url` are the store surface | `src/effects/store.kk:28–48` |
| `rclone link` mints the URL; Nothing for local paths | `src/interp/store_rclone.kk:30–35` |
| config read once from env via `env-or-default` | `src/interp/config_env.kk:14–32` |
| `item-to-ap-object` builds `urls` + addressing from privacy | `src/annex/publish.kk:19–38`; `src/ap/addressing.kk:36–42` |
| `url` field omitted when `urls` empty; single Link unwrapped | `src/ap/object.kk:143–148` |
| `emit-update` builds an `Update`, returns `()` (#654) | `src/ap/outbox.kk:81–94` |
| delivery fans out to `state='accepted'` followers only | `src/ap/outbox.kk:31–39`; SPEC-publish.md §4 / SPEC-federation.md F4 |
| `item` schema columns + `privacy` + indexes; two schema sources | `sql/schema.sql:58–76`; `csrc/db_bridge.c:254–264,309–316` |
| home filters on `privacy IN ('public','unlisted')` | `src/web/handler/home.kk:18–25` |
| `handle-item` 404-for-private authz branch | `src/web/handler/item.kk:25–26` |
| route matchers for publish/unpublish/update | `src/web/route.kk:77–82` |
| upload form privacy select + mirrors fieldset | `src/web/html/upload.kk:22–29,48–72` |
| item page privacy meta + action forms + remotes block | `src/web/html/item.kk:23,61–94` |
| serve installs `with-rclone-store` over `with-process-shell` | `src/annexwyrm.kk:152–153` |
| suites: run.sh (61), run-caddy.sh (110), run-federation.sh (107); gdrive gate | `tests/e2e/run.sh:38,263–265`; SPEC-caddy.md; SPEC-federation.md |
| `upload`/`post_action` helper shapes (positional args, `--form-string`) | `tests/e2e/lib.sh:83–139,317+` |
