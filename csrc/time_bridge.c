/*
 * time_bridge.c — wall clock primitives.
 *
 * ISO 8601 UTC, RFC 7231 HTTP-date, Unix epoch.
 */
#include "annexwyrm.h"

static kk_string_t aw_format_iso(time_t t, kk_context_t* ctx) {
  struct tm gmt;
  gmtime_r(&t, &gmt);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &gmt);
  return aw_str_from_cstr(buf, ctx);
}

static kk_string_t aw_format_http(time_t t, kk_context_t* ctx) {
  struct tm gmt;
  gmtime_r(&t, &gmt);
  char buf[64];
  /* RFC 7231: "Thu, 04 Jun 2026 12:34:56 GMT" */
  strftime(buf, sizeof(buf), "%a, %d %b %Y %H:%M:%S GMT", &gmt);
  return aw_str_from_cstr(buf, ctx);
}

kk_string_t kk_aw_now_iso(kk_context_t* ctx) {
  return aw_format_iso(time(NULL), ctx);
}

kk_string_t kk_aw_now_http(kk_context_t* ctx) {
  return aw_format_http(time(NULL), ctx);
}

kk_integer_t kk_aw_now_unix(kk_context_t* ctx) {
  return kk_integer_from_int64((int64_t)time(NULL), ctx);
}

kk_string_t kk_aw_iso_from_unix(kk_integer_t unix_i, kk_context_t* ctx) {
  int64_t u = kk_integer_clamp64(unix_i, ctx);
  return aw_format_iso((time_t)u, ctx);
}
