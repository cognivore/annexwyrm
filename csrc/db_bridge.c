/*
 * db_bridge.c — SQLite wrapper.
 *
 * The Koka handler holds an opaque "handle" as an int; this file
 * mantains a tiny array mapping handles to sqlite3* pointers.
 *
 * Parameters are passed as a record-separated blob: per param, a tag
 * char ('t'/'i'/'n'), a tab, the value, then 0x1E.
 *
 * Result rows are returned as a single string: cells joined by 0x1F
 * (unit separator), rows joined by 0x1E (record separator). Each cell
 * is tag, tab, value.
 */
#include "annexwyrm.h"

#include <sqlite3.h>

#define MAX_HANDLES 16

static sqlite3* g_handles[MAX_HANDLES];

static int alloc_handle(sqlite3* db) {
  for (int i = 1; i < MAX_HANDLES; ++i) {
    if (!g_handles[i]) { g_handles[i] = db; return i; }
  }
  return -1;
}

kk_integer_t kk_aw_db_open(kk_string_t path, kk_context_t* ctx) {
  kk_ssize_t plen = 0;
  const char* p = aw_cstr(path, &plen, ctx);
  sqlite3* db = NULL;
  int rc = sqlite3_open(p, &db);
  int handle = (rc == SQLITE_OK) ? alloc_handle(db) : -1;
  if (handle < 0 && db) sqlite3_close(db);
  if (handle > 0) {
    /* Always enable foreign keys and WAL mode. */
    sqlite3_exec(db, "PRAGMA foreign_keys=ON;", NULL, NULL, NULL);
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    /* busy_timeout is mandatory once more than one process touches this DB:
     * the `serve` daemon's delivery tick and a concurrent `annexwyrm drain`
     * (or two daemons in the federation e2e) are separate WAL writers. With
     * the default timeout of 0, the second writer's sqlite3_step returns
     * SQLITE_BUSY *immediately*; kk_aw_db_exec reports that as changes=-1 and
     * every caller discards the return, so the UPDATE is silently dropped —
     * a delivered activity never transitions out of `pending` and gets
     * re-POSTed. 5s of wait-and-retry makes collided writers serialize
     * instead of losing their write. */
    sqlite3_busy_timeout(db, 5000);
  }
  kk_string_drop(path, ctx);
  return kk_integer_from_int(handle, ctx);
}

kk_unit_t kk_aw_db_close(kk_integer_t h_i, kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    sqlite3_close(g_handles[h]);
    g_handles[h] = NULL;
  }
  return kk_Unit;
}

/* Bind a single tag/value pair to position `pos` of `stmt`.
 * Returns 1 on success. */
static int bind_one(sqlite3_stmt* stmt, int pos, char tag, const char* val, size_t len) {
  switch (tag) {
    case 'n': return sqlite3_bind_null(stmt, pos) == SQLITE_OK;
    case 't': return sqlite3_bind_text(stmt, pos, val, (int)len, SQLITE_TRANSIENT) == SQLITE_OK;
    case 'i': {
      long long n = strtoll(val, NULL, 10);
      return sqlite3_bind_int64(stmt, pos, n) == SQLITE_OK;
    }
    default: return 0;
  }
}

/* Walk the params blob (`<tag>\t<value>\x1e`)*, binding each. */
static int bind_params(sqlite3_stmt* stmt, const char* params, size_t plen) {
  int pos = 1;
  const char* p = params;
  const char* end = params + plen;
  while (p < end) {
    if (p + 2 > end) return 0;
    char tag = p[0];
    if (p[1] != '\t') return 0;
    p += 2;
    const char* vstart = p;
    while (p < end && *p != 0x1E) ++p;
    if (p >= end) return 0;
    if (!bind_one(stmt, pos++, tag, vstart, (size_t)(p - vstart))) return 0;
    ++p;  /* skip 0x1E */
  }
  return 1;
}

kk_integer_t kk_aw_db_exec(kk_integer_t h_i, kk_string_t sql,
                           kk_string_t params, kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  kk_ssize_t sqllen = 0, plen = 0;
  const char* sql_s = aw_cstr(sql, &sqllen, ctx);
  const char* p_s   = aw_cstr(params, &plen, ctx);
  int changes = -1;

  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    sqlite3_stmt* stmt = NULL;
    if (sqlite3_prepare_v2(g_handles[h], sql_s, (int)sqllen, &stmt, NULL) == SQLITE_OK) {
      if (bind_params(stmt, p_s, (size_t)plen)) {
        int rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE || rc == SQLITE_ROW) {
          changes = sqlite3_changes(g_handles[h]);
        }
      }
      sqlite3_finalize(stmt);
    }
  }

  kk_string_drop(sql, ctx);
  kk_string_drop(params, ctx);
  return kk_integer_from_int(changes, ctx);
}

/* Append `c` (1 char) to a growing buffer. */
static int buf_putc(char** buf, size_t* len, size_t* cap, char c) {
  if (*len + 1 >= *cap) {
    size_t newcap = *cap ? *cap * 2 : 256;
    char* nb = (char*)realloc(*buf, newcap);
    if (!nb) return 0;
    *buf = nb;
    *cap = newcap;
  }
  (*buf)[(*len)++] = c;
  return 1;
}

static int buf_puts(char** buf, size_t* len, size_t* cap, const char* s, size_t n) {
  if (*len + n >= *cap) {
    size_t newcap = *cap ? *cap * 2 : 256;
    while (newcap < *len + n + 1) newcap *= 2;
    char* nb = (char*)realloc(*buf, newcap);
    if (!nb) return 0;
    *buf = nb;
    *cap = newcap;
  }
  memcpy(*buf + *len, s, n);
  *len += n;
  return 1;
}

kk_string_t kk_aw_db_query(kk_integer_t h_i, kk_string_t sql,
                           kk_string_t params, kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  kk_ssize_t sqllen = 0, plen = 0;
  const char* sql_s = aw_cstr(sql, &sqllen, ctx);
  const char* p_s   = aw_cstr(params, &plen, ctx);

  char* buf = NULL;
  size_t blen = 0, bcap = 0;

  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    sqlite3_stmt* stmt = NULL;
    if (sqlite3_prepare_v2(g_handles[h], sql_s, (int)sqllen, &stmt, NULL) == SQLITE_OK) {
      if (bind_params(stmt, p_s, (size_t)plen)) {
        int rc;
        int first_row = 1;
        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
          if (!first_row) buf_putc(&buf, &blen, &bcap, 0x1E);
          first_row = 0;
          int cols = sqlite3_column_count(stmt);
          for (int c = 0; c < cols; ++c) {
            if (c) buf_putc(&buf, &blen, &bcap, 0x1F);
            int t = sqlite3_column_type(stmt, c);
            if (t == SQLITE_NULL) {
              buf_puts(&buf, &blen, &bcap, "n\t", 2);
            } else if (t == SQLITE_INTEGER) {
              char tmp[32];
              int n = snprintf(tmp, sizeof(tmp), "i\t%lld",
                               (long long)sqlite3_column_int64(stmt, c));
              buf_puts(&buf, &blen, &bcap, tmp, (size_t)n);
            } else {
              buf_puts(&buf, &blen, &bcap, "t\t", 2);
              const unsigned char* v = sqlite3_column_text(stmt, c);
              int n = sqlite3_column_bytes(stmt, c);
              if (v && n > 0) buf_puts(&buf, &blen, &bcap, (const char*)v, (size_t)n);
            }
          }
        }
      }
      sqlite3_finalize(stmt);
    }
  }

  kk_string_drop(sql, ctx);
  kk_string_drop(params, ctx);

  kk_string_t result;
  if (buf && blen > 0) {
    result = aw_str_from_bytes((uint8_t*)buf, blen, ctx);
  } else {
    result = aw_str_empty(ctx);
  }
  free(buf);
  return result;
}

kk_integer_t kk_aw_db_last_rowid(kk_integer_t h_i, kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  long long id = 0;
  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    id = sqlite3_last_insert_rowid(g_handles[h]);
  }
  return kk_integer_from_int64(id, ctx);
}

/* Run a multi-statement SQL script via sqlite3_exec. Used by init. */
kk_integer_t kk_aw_db_exec_script(kk_integer_t h_i, kk_string_t sql,
                                   kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  kk_ssize_t slen = 0;
  const char* s = aw_cstr(sql, &slen, ctx);
  int rc = SQLITE_ERROR;
  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    rc = sqlite3_exec(g_handles[h], s, NULL, NULL, NULL);
  }
  kk_string_drop(sql, ctx);
  return kk_integer_from_int(rc, ctx);
}

/* The schema, embedded in the binary so `init` doesn't have to find the
 * source tree. Edits MUST be mirrored to sql/schema.sql. */
static const char ANNEXWYRM_SCHEMA[] =
  "PRAGMA journal_mode = WAL;"
  "PRAGMA foreign_keys = ON;"
  "CREATE TABLE IF NOT EXISTS actor ("
  "  id TEXT PRIMARY KEY, local INTEGER NOT NULL,"
  "  username TEXT NOT NULL, domain TEXT NOT NULL,"
  "  name TEXT, summary TEXT, icon_url TEXT,"
  "  inbox TEXT NOT NULL, outbox TEXT NOT NULL,"
  "  followers TEXT NOT NULL, following TEXT NOT NULL,"
  "  shared_inbox TEXT,"
  "  public_key_pem TEXT NOT NULL, private_key_pem TEXT,"
  "  manually_approves INTEGER NOT NULL DEFAULT 0,"
  "  discoverable INTEGER NOT NULL DEFAULT 1,"
  "  created_at TEXT NOT NULL, fetched_at TEXT);"
  "CREATE UNIQUE INDEX IF NOT EXISTS actor_local_user"
  "  ON actor(domain, username) WHERE local = 1;"
  "CREATE TABLE IF NOT EXISTS local_login ("
  "  actor_id TEXT PRIMARY KEY REFERENCES actor(id) ON DELETE CASCADE,"
  "  password_hash TEXT NOT NULL, created_at TEXT NOT NULL);"
  "CREATE TABLE IF NOT EXISTS session ("
  "  token TEXT PRIMARY KEY,"
  "  actor_id TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,"
  "  created_at TEXT NOT NULL, expires_at TEXT NOT NULL);"
  "CREATE TABLE IF NOT EXISTS item ("
  "  id TEXT PRIMARY KEY,"
  "  owner_id TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,"
  "  object_type TEXT NOT NULL, privacy TEXT NOT NULL,"
  "  name TEXT, summary TEXT, content TEXT, media_type TEXT,"
  "  byte_size INTEGER, sha256 TEXT,"
  "  rating INTEGER, in_reply_to TEXT,"
  "  published_at TEXT NOT NULL, updated_at TEXT NOT NULL);"
  "CREATE INDEX IF NOT EXISTS item_owner_published ON item(owner_id, published_at DESC);"
  "CREATE INDEX IF NOT EXISTS item_privacy_published ON item(privacy, published_at DESC);"
  "CREATE INDEX IF NOT EXISTS item_in_reply_to ON item(in_reply_to);"
  "CREATE TABLE IF NOT EXISTS item_remote ("
  "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  "  item_id TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,"
  "  kind TEXT NOT NULL, target TEXT NOT NULL,"
  "  media_type TEXT, label TEXT,"
  "  published INTEGER NOT NULL DEFAULT 0,"
  "  sort_order INTEGER NOT NULL DEFAULT 0,"
  "  created_at TEXT NOT NULL);"
  "CREATE INDEX IF NOT EXISTS item_remote_item ON item_remote(item_id, sort_order);"
  "CREATE TABLE IF NOT EXISTS activity ("
  "  id TEXT PRIMARY KEY, actor_id TEXT NOT NULL,"
  "  type TEXT NOT NULL, object_id TEXT, target_id TEXT,"
  "  inbox_remote INTEGER NOT NULL, raw TEXT NOT NULL,"
  "  addressed_to TEXT NOT NULL, received_at TEXT NOT NULL);"
  "CREATE INDEX IF NOT EXISTS activity_actor ON activity(actor_id, received_at DESC);"
  "CREATE INDEX IF NOT EXISTS activity_object ON activity(object_id);"
  "CREATE TABLE IF NOT EXISTS follow ("
  "  id TEXT PRIMARY KEY, follower_id TEXT NOT NULL,"
  "  target_id TEXT NOT NULL, state TEXT NOT NULL,"
  "  created_at TEXT NOT NULL, accepted_at TEXT);"
  "CREATE UNIQUE INDEX IF NOT EXISTS follow_pair ON follow(follower_id, target_id);"
  "CREATE INDEX IF NOT EXISTS follow_target_state ON follow(target_id, state);"
  "CREATE TABLE IF NOT EXISTS like_ ("
  "  id TEXT PRIMARY KEY, actor_id TEXT NOT NULL,"
  "  object_id TEXT NOT NULL, created_at TEXT NOT NULL);"
  "CREATE UNIQUE INDEX IF NOT EXISTS like_pair ON like_(actor_id, object_id);"
  "CREATE INDEX IF NOT EXISTS like_object ON like_(object_id);"
  "CREATE TABLE IF NOT EXISTS announce ("
  "  id TEXT PRIMARY KEY, actor_id TEXT NOT NULL,"
  "  object_id TEXT NOT NULL, created_at TEXT NOT NULL);"
  "CREATE UNIQUE INDEX IF NOT EXISTS announce_pair ON announce(actor_id, object_id);"
  "CREATE INDEX IF NOT EXISTS announce_object ON announce(object_id);"
  "CREATE TABLE IF NOT EXISTS delivery ("
  "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
  "  activity_id TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,"
  "  sender_id TEXT NOT NULL REFERENCES actor(id) ON DELETE CASCADE,"
  "  inbox_url TEXT NOT NULL, next_attempt TEXT NOT NULL,"
  "  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,"
  "  state TEXT NOT NULL DEFAULT 'pending');"
  "CREATE INDEX IF NOT EXISTS delivery_ready ON delivery(state, next_attempt);"
  "CREATE TABLE IF NOT EXISTS setting ("
  "  key TEXT PRIMARY KEY, value TEXT NOT NULL);"
;

kk_integer_t kk_aw_db_init_schema(kk_integer_t h_i, kk_context_t* ctx) {
  int h = (int)kk_integer_clamp32(h_i, ctx);
  int rc = SQLITE_ERROR;
  if (h > 0 && h < MAX_HANDLES && g_handles[h]) {
    rc = sqlite3_exec(g_handles[h], ANNEXWYRM_SCHEMA, NULL, NULL, NULL);
  }
  return kk_integer_from_int(rc, ctx);
}
