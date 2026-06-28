# Multitenancy

> annexwyrm runs many tenants on one instance. Invite-only. Tenants share a
> single browsable archive — anyone logged in can view anyone's files — but
> **each tenant brings its own rclone/backup backend**, so a tenant's bytes
> always live on *that tenant's* cloud.

This document is the authoritative description of the multitenant model:
the data model, the authorization rules, the per-tenant storage flow, how
federation stays per-actor, and the security/trust boundaries. Read it before
touching auth, storage, or the AP outbox.

---

## 1. The shape of it

- **Many local actors.** The `actor` table always supported `local=1` rows;
  now there are many, one per tenant, each with its own RSA keypair and
  `local_login`. The bootstrap actor (created at `init` from
  `ANNEXWYRM_USERNAME`) is the **admin** (`is_admin=1`) and the only one who
  can mint invites.
- **Invite-only.** No open sign-up. An admin mints a single-use token at
  `/invites`; `/register?invite=<token>` consumes it to create a tenant and
  logs them straight in, pointed at `/settings` to configure storage.
- **One shared archive.** Home / search / tags list every tenant's items, each
  attributed to its author (`by <user>`). The item page and its review are
  world-readable (federation needs that). **Any logged-in tenant can download
  any item's archived file** — that is the cross-tenant sharing promise.
- **Per-tenant storage.** A tenant pastes its own `rclone.conf` and names its
  archive + public remotes in `/settings`. Uploads land on *its* cloud; a
  cross-tenant download decrypts/streams through the **owner's** config, never
  the viewer's.

---

## 2. Data model

New since single-tenant (see `sql/schema.sql`, mirrored in
`csrc/db_bridge.c`):

| change | what |
|---|---|
| `actor.is_admin` | `INTEGER NOT NULL DEFAULT 0`. 1 = may mint invites. Idempotent column-add migration (`aw_migrate_actor`). |
| `tenant_storage` | per-actor rclone backend: `rclone_conf` (verbatim, `''` = ambient), `archive_remote`, `public_remote`, `public_url_base`. |
| `invite` | single-use tokens: `token`, `created_by`, `note`, `expires_at`, `used_by` (NULL = open), `used_at`. |

`item.owner_id`, `session.actor_id`, `delivery.sender_id` already keyed off the
actor — multitenancy mostly *uses* columns the schema already had.

---

## 3. Authorization (`src/web/session.kk`)

The single-tenant `is-owner-session` ("is this THE owner?") is gone. Three
precise checks replace it:

| check | meaning | gates |
|---|---|---|
| `is-tenant-session(req)` | any logged-in local actor | upload, **download any tenant's file**, follow/unfollow, view settings |
| `is-owner-of(req, owner)` / `session-actor(req) == it.owner` | the session actor owns this item | edit / publish-file / retract MY item |
| `is-admin-session(req)` | the bootstrap tenant | mint invites |

Messages distinguish "login required" (no session) from "not your item"
(logged in, wrong owner). A peer can **read and download** another tenant's
file but can never **mutate** it, and can never see or edit another tenant's
storage config.

---

## 4. Per-tenant storage (`src/annex/storage.kk`, `src/interp/store_rclone.kk`)

The chain, for any blob op:

1. The handler knows the **owner** of the blob's item (its own session actor on
   upload; `it.owner` on read/publish/edit).
2. `load-tenant-store(owner)` reads `tenant_storage`, and **materialises** the
   owner's `rclone_conf` to a `0600` file under `<data-dir>/storage/` via the
   `materialize-conf` store op (C bridge `aw_write_private_file`, atomic
   mkstemp+rename). Secrets reach the filesystem only — never argv or env.
3. `ts.archive-loc(key)` / `ts.pubrem-loc(key)` build a `blob-loc` carrying the
   remote target, the key, the **conf path**, and the **url-base**.
4. `store_rclone` runs `rclone --config <conf> <op> <remote>/<key>` (no
   `--config` when conf is `""` = ambient). `blob-public-url` uses the
   tenant's `url-base` when set, else `rclone link`.

`blob-loc` gained `conf` + `url-base` (both strings — the struct stays
all-reference, koka#654-safe). `Blob-loc(...)` is built only through the
`tenant-store` helpers; nothing constructs blob locations from global config
anymore.

**The admin tenant** keeps `rclone_conf=''` (ambient `~/.config/rclone`) and
gets its `archive_remote`/`public_remote`/`public_url_base` from the
`ANNEXWYRM_*_REMOTE` env vars, re-seeded on every `init` **and** `serve` start
(`bootstrap-admin`). That is why prod (and the e2e, which sets the remote env
on `serve`) keep working unchanged: the admin storage is env-managed; new
tenants are DB-managed via `/settings` and never touched by the seed.

---

## 5. Federation stays per-actor (`src/ap/outbox.kk`, `persist.kk`, `inbox.kk`)

`local-actor-url()` is no longer the implicit sender. The **acting actor** is
explicit:

- `emit-create/update/delete(item)` use `item.owner`.
- `emit-follow/undo-follow/like/announce` take the session actor.
- `queue-delivery(aid, inbox, sender)` writes `sender_id = acting actor`, and
  the delivery worker signs each POST with **that actor's** private key
  (already keyed off `sender_id`). So each tenant federates under its own key,
  its own `/followers`, its own outbox.
- Incoming `Follow` matches **any** local actor and honours **that actor's**
  `manually_approves`.

The AP handlers (`actor`, `outbox`, `followers`, `following`, `inbox`,
`webfinger`) resolve the requested username against local actors
(`local-actor-id-for`) instead of comparing to the one configured name.

---

## 6. Security model & trust boundaries

What the design guarantees:

- **No anonymous file access.** `/items/<id>/file` requires a session; only a
  published file's *external* public link is world-reachable (unchanged).
- **No cross-tenant mutation.** Only an item's owner edits/publishes/retracts
  it; only a tenant edits its own storage. Authz is checked on every mutation.
- **Secret hygiene.** rclone configs live in the DB (same trust as the actors'
  private keys) and are materialised to `0600` files; never on argv/env. The
  `/settings` GET sends `Cache-Control: no-store` (it echoes the config back).
  A tenant only ever sees its **own** config.
- **Invites.** 256-bit tokens, single-use (consumed transactionally on
  register), expiry-enforced. The serve loop is single-threaded, so there is no
  intra-daemon claim race.
- **Username hygiene.** Normalised to `[a-z0-9_-]`, length-capped, reserved
  words blocked — a username is always a clean `/users/<u>` segment and
  WebFinger handle, never an injection vector.
- **rclone target validation.** A tenant's `archive`/`public` must be
  **named-remote references** (`name:path`); bare local paths, `:local:`
  connection strings, and `-flag` tokens are rejected, and a config declaring
  `type = local`/`alias` is refused. This stops a tenant from pointing rclone
  at the daemon's filesystem through the easy vectors.

**Residual trust boundary (document + operate around it):** a tenant supplies
its own rclone config, and rclone with a cloud backend can reach external hosts
(and a sufficiently creative config is a large surface). Treat a tenant's
config as semi-trusted input:

1. Run annexwyrm as a **dedicated unprivileged user** with minimal filesystem
   access (prod already does, via the systemd unit). The `0600` storage configs
   and the SQLite DB are the only sensitive files in its reach.
2. Invite-only means the **admin vets every tenant**. Don't hand invites to
   the untrusted public.

These two operational controls plus the validation above are the security
posture for v1. Deeper sandboxing of rclone (namespaces/seccomp) is a possible
future hardening, not required for the invite-only model.

---

## 7. Operator guide

**Invite a tenant.** Log in as the admin (the `ANNEXWYRM_USERNAME` actor) →
`/invites` → *mint invite* → copy the `…/register?invite=<token>` URL and send
it. It expires in 14 days and works once.

**A tenant joins.** Opens the invite link → picks a handle + password →
lands on `/settings`. There they paste their `rclone.conf`, set the archive
remote (encrypted; e.g. `archive-crypt:annexwyrm`) and public remote
(downloads; e.g. `public:annexwyrm-public`), optionally a public URL base for a
CDN/S3 bucket. Until storage is set, **file uploads are refused** (file-less
text reviews still work).

**Admin storage** comes from the environment (`ANNEXWYRM_ARCHIVE_REMOTE`,
`ANNEXWYRM_PUBLIC_REMOTE`, `ANNEXWYRM_PUBLIC_URL_BASE`) and is re-applied on
restart. To change it, change the env and restart — editing it in `/settings`
will be overwritten on the next `serve`.

**Routes added:** `GET/POST /register`, `GET/POST /invites`,
`POST /settings/storage`.

---

## 8. Gotchas for the next agent

- **`public` is a Koka keyword.** You cannot name a field/variable `public`
  (the storage struct field is `pubrem`, the helper is `pubrem-loc`). `pub` and
  `public` both lex as the visibility keyword.
- **koka#654 still bites.** When you construct an `annex-item` (a value struct
  mixing `int`/`bool` with strings) and then have an effectful tail that
  captures it across a bind, codegen panics. The fix used in
  `handle-item-edit-post`: resolve everything effectful (e.g.
  `load-tenant-store`) **before** building the item, so the struct is
  constructed and consumed with no effectful bind between. Two such items
  captured together is the specific trigger.
- **New `.kk`/`.c` files must be `git add`ed** — the flake builds from the git
  tree. New files added for this feature: `src/annex/storage.kk`,
  `src/web/session.kk`, `src/web/handler/register.kk`,
  `src/web/handler/invites.kk`, `src/web/html/register.kk`,
  `src/web/html/invites.kk`, `csrc/fs_bridge.c`.
