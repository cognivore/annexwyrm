# Handoff — lists / shelves feature

_Written 2026-06-07. Audience: the next agent (or human) picking up the
bookwyrm-style **lists / shelves** feature. Everything below is current as of
this commit; verify file/line references still hold before relying on them._

---

## 1. What's already done (don't redo it)

- **Reviews imported.** All 217 bookwyrm reviews are live on prod
  (`https://wyrm.fere.me`) as **file-less items**: `byte_size=0`, no
  `item_remote` rows, `object_type='Note'`, `in_reply_to=<canonical book URL>`
  (the bookwyrm `edition.id`, e.g. `https://bookwyrm.social/book/2160529`).
  Created via the file-less branch of `handle-upload-post`
  (`src/web/handler/upload.kk` → `ingest-textonly`).
- **Original timestamps preserved.** `published_at`/`updated_at` were back-dated
  to each review's original bookwyrm `published` date, so the genuinely-latest
  review (the Kamigawa booklet, `2026-06-06`) sorts topmost. Done in place with
  `/tmp/fix_dates.py` (a throwaway sidecar; see §6).
- **Pagination shipped.** Home / search / single-tag listings paginate at
  `items-per-page = 50` with on-page controls. See `src/web/html/home.kk`
  (`pagination`, `page-windows`, `page-link`), the handlers
  (`src/web/handler/home.kk`, `src/web/handler/search.kk`), and
  `src/core/url.kk:page-param`. **Reuse `pagination(base, page, total, size)`**
  for any list pages you add — `base` is the href prefix up to and including
  `page=`, the link for page N is `base ++ N.show` (then `esc`'d). CSS lives in
  `static/style.css` under `nav.pagination`.
- **Score mapping is settled.** bookwyrm 1–5 → annexwyrm −3..+3 is
  `round((r−3)×1.5)` clamped to [−3,3]; unrated/`None`/≤0 → 99 (the unrated
  sentinel). Don't re-derive it; copy from `/tmp/import_bookwyrm.py:map_rating`.

## 2. The goal

Recreate bookwyrm's shelves + custom lists on annexwyrm, then import the
membership from the export. The data we need to represent (from
`~/Downloads/bookwyrm-account-export.tar.gz`, extracted at `/tmp/bw-export/`):

**Built-in shelves** (bookwyrm reading-status shelves):

| shelf              | books | bookwyrm shelf id suffix |
|--------------------|-------|--------------------------|
| Read               | 163   | `/books/read`            |
| To Read            | 65    | `/books/to-read`         |
| Currently Reading  | 7     | `/books/reading`         |
| Stopped Reading    | 4     | `/books/stopped-reading` |

**Custom lists** (bookwyrm `BookList` objects):

| list                       | books |
|----------------------------|-------|
| Serious books              | 4     |
| Amazing Fair Play Mystery  | 1     |

Total: **272 books** in the export (each has an `edition.id`). Note this is
MORE than the 217 reviews — most shelved books (especially To Read) have **no
review**. That asymmetry is the central design decision (§3).

## 3. The one real design decision: books vs. items

Shelves in bookwyrm hold **books**. annexwyrm's unit is the **item** (a review).
~55 shelved books have no corresponding item. You must pick one model:

- **Option A — lists reference book URLs directly.** A `list_item` row stores
  the canonical book URL (`edition.id`); if a local review item exists for that
  URL (`item.in_reply_to = book_url`), the list entry links to it, otherwise it
  renders as a bare "to-read" entry (title + link out to bookwyrm). Pros: no
  fake items, matches "a shelf is a list of books." Cons: list rendering must
  LEFT JOIN `item ON item.in_reply_to = book_url` and carry a book title/URL of
  its own (the export has `edition.title`).
- **Option B — stub items for every shelved book.** Create a file-less item for
  each book even when unreviewed (empty content), so lists uniformly reference
  `item.id`. Pros: one foreign key, uniform rendering, books show in the
  archive feed too. Cons: 55 empty "reviews" pollute the archive/feed and
  **federate as empty Notes** (bad — Mastodon would show blank posts). If you
  pick B you MUST exclude content-empty items from the feed and from
  federation.

**Recommendation: Option A.** It keeps the archive/feed clean and federates
nothing empty. The list page becomes its own view, not a slice of the feed.

## 4. Suggested implementation (Option A)

### Schema (`csrc/db_bridge.c`, the `aw_init_schema` batch ~line 280–360)

The schema is created by a single C string of `CREATE TABLE IF NOT EXISTS …`
statements, and there's an idempotent column-migration path
(`aw_migrate_item`). Add new tables to the batch (they're `IF NOT EXISTS`, so
existing prod DBs pick them up on next `init`/startup — confirm the schema
batch runs on every startup, not just `init`; see `aw_open`/`aw_init`):

```sql
CREATE TABLE IF NOT EXISTS list (
  id          TEXT PRIMARY KEY,           -- <base>/lists/<slug>
  owner_id    TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,              -- "Read", "Serious books"
  slug        TEXT NOT NULL UNIQUE,       -- "read", "serious-books"
  kind        TEXT NOT NULL,              -- 'shelf' | 'list'
  created_at  TEXT NOT NULL );

CREATE TABLE IF NOT EXISTS list_item (
  list_id     TEXT NOT NULL REFERENCES list(id) ON DELETE CASCADE,
  book_url    TEXT NOT NULL,             -- canonical edition.id (== item.in_reply_to)
  book_title  TEXT NOT NULL DEFAULT '',  -- edition.title, for books with no local item
  sort_order  INTEGER NOT NULL DEFAULT 0,
  added_at    TEXT NOT NULL DEFAULT '',  -- readthrough finish/start date if known
  PRIMARY KEY (list_id, book_url) );
CREATE INDEX IF NOT EXISTS list_item_book ON list_item(book_url);
```

Rendering a list = `SELECT li.book_url, li.book_title, i.id, i.name, i.rating,
i.published_at FROM list_item li LEFT JOIN item i ON i.in_reply_to = li.book_url
WHERE li.list_id = ? ORDER BY li.sort_order, li.added_at DESC LIMIT ? OFFSET ?`.

### Effect / persistence layer

- Add a `effects/db`-backed module `src/annex/list.kk` (or fold into an existing
  `annex/` module) with `save-list`, `load-list-by-slug`, `list-members(slug,
  page, size)`, `count-list(slug)`, `all-lists()`. Mirror the SQL idiom in
  `src/web/handler/search.kk` (bound params via `txt`/`num`, `query`,
  `first-int`).

### Routes (`src/web/route.kk`)

Add, near the `tags` routes (~line 90):

```
("GET", Cons("lists", Nil))            -> handle-lists-index(req)     // all shelves+lists
("GET", Cons("lists", Cons(slug,Nil))) -> handle-list(req, slug)      // one list, paginated
```

If you want owner-side editing: `POST /lists` (create), `POST
/lists/<slug>/add`, `POST /lists/<slug>/remove`, all gated by
`is-owner-session(req)` exactly like `handle-upload-form`
(`src/web/handler/upload.kk:38`).

### HTML (`src/web/html/`)

- `list.kk`: `render-lists-index(lists)` and `render-list(list, rows, page,
  total, size)`. Reuse `web/html/home`'s `render-item-list` for rows that have a
  local item; render a plain "title → bookwyrm link" row for book-only entries.
  **Call `pagination("/lists/" ++ slug ++ "?page=", page, total, size)`.**
- Add a nav link to `/lists` in `src/web/html/layout.kk` (the `<span
  class="nav">` block) so shelves are reachable.

### ActivityPub (optional, do LAST)

Federating shelves is **optional** and Mastodon won't render them as anything
useful (it only renders `Note`/`Article` as posts; collections aren't shown in
a timeline). If you do it, model each list as an `OrderedCollection` at its `id`
with `OrderedCollectionPage`s — copy the paging shape from
`src/web/handler/followers.kk` + `src/ap/collection.kk` (`Ap-collection`,
`Ap-page`, `page-id-for`, `default-page-size`). **Do not** emit `Create`
activities for list membership; bookwyrm uses `Add`/`Remove` activities against
the collection, which Mastodon ignores anyway. Recommend skipping AP for v1.

## 5. Security audit checklist (run before deploy)

The codebase has a real audit history (see `NOTES.md` §"Security audit
(2026-06-06)"). For this feature specifically:

- **Authz on every mutation.** `POST /lists*` MUST check `is-owner-session`;
  anonymous and non-owner sessions get `forbidden`. Lists are single-tenant —
  only the local owner edits.
- **No SQL injection.** Every query uses bound params (`txt`/`num`), never
  string interpolation of `slug`/`name`/`book_url`. Follow the existing idiom.
- **Slug normalisation.** Normalise list slugs like tags are normalised
  (`parse-tags` in `annex/item`) — URL/HTML-safe word chars only — so
  `/lists/<slug>` can't be used for path traversal or XSS. A segment that
  normalises to nothing is a real 404 (mirror `handle-tag`).
- **XSS on render.** `esc()` every `name`/`book_title`/`book_url` placed in
  HTML. `book_url` placed in an `href` must additionally pass
  `safe-url` (`src/core/markdown.kk`) — reject non-http(s) so a
  `javascript:`-scheme book URL can't become a live anchor (this exact class of
  bug was a confirmed XSS finding; see `review-of-block` in
  `src/web/html/item.kk`).
- **No private-blob leak.** Lists reference reviews, not blobs — but if a list
  row links to a published file, reuse the existing `file_published` gate. Never
  surface an archived item's download URL to anon (HTML or AP JSON). The e2e
  asserts this (`tests/e2e/run.sh` Step A (e)).
- **Pagination clamp.** Clamp `?page=` into `[1, pages]` (copy `clamp-page` from
  `src/web/handler/search.kk`) so a hand-typed cursor can't make a negative
  offset.

Then: `nix build .#default` (the canonical build — `just build` is broken on
this darwin host), add e2e assertions to `tests/e2e/run.sh` (a "Step R — lists"
mirroring Step Q's structure), and run all three suites:
`just test-e2e`, `just test-e2e-caddy`, `just test-e2e-federation`.

## 6. Import (do this AFTER the feature is deployed)

The reviews importer is `/tmp/import_bookwyrm.py` (throwaway sidecar, NOT in the
repo — these scripts are intentionally ugly one-offs). Write a sibling
`import_lists.py` that:

1. Reads `/tmp/bw-export/archive.json` (extracted from the tarball).
2. For each `book` in `d["books"]`: `book_url = book["edition"]["id"]`,
   `book_title = book["edition"]["title"]`.
3. For each `shelf` in `book["shelves"]` (objects with `name` + `id`): map the
   bookwyrm shelf name → a local shelf slug (Read→`read`, To Read→`to-read`,
   Currently Reading→`reading`, Stopped Reading→`stopped-reading`). Upsert a
   `list` row (kind `shelf`) and a `list_item` row.
4. For each `list` in `book["lists"]` (`type: "BookList"`, has `name`): upsert a
   `list` row (kind `list`) + `list_item`.
5. For `added_at`/`sort_order`, prefer the matching `readthrough`'s
   `finish_date` (or `start_date`/`stopped_date`) — `book["readthroughs"]` has
   `start_date`, `finish_date`, `stopped_date`, `created_date`.

**Decide import mechanism:** either (a) POST to owner-gated `/lists/*` endpoints
(needs the endpoints + a login cookie; password via
`rageveil show annexwyrm.localhost/sweater/password`), or (b) direct SQL
`INSERT` against the prod DB (`/var/lib/annexwyrm/annexwyrm.db` on
`root@chat.md110.se`) like `fix_dates.py` did. **Back up the DB first**
(`cp annexwyrm.db annexwyrm.db.bak-$(date +%s)`) and **dry-run** (SELECT counts)
before writing — that's how the timestamp fix was de-risked.

Expected magnitudes after import: ~239 shelf memberships + 5 list memberships
across 4 shelves + 2 lists.

## 7. House rules / gotchas (read `NOTES.md` too)

- **Koka 3.2.3 traps:** `raw` is reserved; `0x1d.char` fails (hex-float
  ambiguity — use decimal `29.char`); `"\x1dD"` greedily eats the next hex
  letter; leading-dot multiline method chains don't parse; non-structural
  recursion needs the `div` effect. (`page-param` and `query-parse` carry `div`
  for this reason — your list helpers that parse query strings will too.)
- **New `.kk` files MUST be `git add`ed** — the flake builds from the git tree;
  untracked files are invisible to `nix build` (dirty tracked files ARE picked
  up). New C/schema goes in `csrc/`, which is also git-tracked.
- **`\x1f`/`\x1e` bridge framing:** any new C↔Koka bridge record keeps the
  binary/long field LAST and uses `split-limit`. You almost certainly won't
  touch the bridge for this feature (it's pure SQL), but if you do, see
  `NOTES.md` §"Bridge record framing".
- **Deploy:** `./deploy.sh` (rsync → `/opt`, native koka build, restart) to prod
  `root@chat.md110.se`. prod is canonical (`@sweater@wyrm.fere.me`); laptop
  instances are secondary. **Never** set `ANNEXWYRM_ALLOW_PRIVATE_EGRESS=1` in
  prod (test-only SSRF seam). Secrets via `rageveil`, never literals.
- **Federation caution:** do NOT use the `refresh` CLI (Delete+Create
  tombstones a URI so the re-Create is dropped — it ate a post once). Use
  `publish` (Create only). Don't federate empty Notes.

## 8. Quick start for the next agent

1. Extract the export if `/tmp/bw-export/` is gone:
   `mkdir -p /tmp/bw-export && tar xzf ~/Downloads/bookwyrm-account-export.tar.gz -C /tmp/bw-export`.
2. Re-read `archive.json` shape: each `book` has `edition` (`id`, `title`),
   `shelves[]`, `lists[]`, `readthroughs[]`, `reviews[]`.
3. Implement schema → persistence → routes → HTML (Option A), reusing
   `pagination()` and the search-handler SQL idiom.
4. Security-audit per §5, `nix build .#default`, add e2e Step R, run all suites.
5. Commit (message ends with the `Co-Authored-By` trailer the repo uses),
   `./deploy.sh`, then run `import_lists.py` against prod (backup + dry-run
   first).
