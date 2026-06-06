/*
 * time_bridge.c — wall clock primitives.
 *
 * ISO 8601 UTC, RFC 7231 HTTP-date, Unix epoch.
 */
#define _GNU_SOURCE
#include "aw_bridge.h"
#include <time.h>

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

/* Parse an RFC 7231 IMF-fixdate ("Thu, 04 Jun 2026 12:34:56 GMT", always
 * GMT) to Unix seconds, or -1 on parse failure. Used to enforce a freshness
 * window on signed inbound activities (anti-replay). We avoid strptime's
 * locale/%b quirks by parsing the fixed fields ourselves and converting with
 * a civil-days algorithm (no timegm dependency, fully UTC, locale-free). */
static int month_num(const char* m) {
  static const char* names = "JanFebMarAprMayJunJulAugSepOctNovDec";
  for (int i = 0; i < 12; ++i)
    if (m[0] == names[i*3] && m[1] == names[i*3+1] && m[2] == names[i*3+2])
      return i + 1;
  return 0;
}

/* days since 1970-01-01 for a y/m/d (Howard Hinnant's days_from_civil). */
static long long days_from_civil(long long y, unsigned m, unsigned d) {
  y -= (m <= 2);
  long long era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (long long)doe - 719468;
}

kk_integer_t kk_aw_parse_http_date(kk_string_t s, kk_context_t* ctx) {
  kk_ssize_t len = 0;
  const char* p = aw_cstr(s, &len, ctx);
  long long result = -1;
  /* Expect: "Wdy, DD Mon YYYY HH:MM:SS GMT" — find the first comma+space. */
  if (p && len >= 25) {
    const char* c = NULL;
    for (kk_ssize_t i = 0; i + 1 < len; ++i)
      if (p[i] == ',' && p[i+1] == ' ') { c = p + i + 2; break; }
    if (c) {
      int dd, yyyy, hh, mm, ss;
      char mon[4] = {0};
      /* "DD Mon YYYY HH:MM:SS" */
      if (sscanf(c, "%d %3s %d %d:%d:%d", &dd, mon, &yyyy, &hh, &mm, &ss) == 6) {
        int mo = month_num(mon);
        if (mo >= 1 && dd >= 1 && dd <= 31 &&
            hh >= 0 && hh < 24 && mm >= 0 && mm < 60 && ss >= 0 && ss < 61) {
          long long days = days_from_civil(yyyy, (unsigned)mo, (unsigned)dd);
          result = days * 86400LL + hh * 3600LL + mm * 60LL + ss;
        }
      }
    }
  }
  kk_string_drop(s, ctx);
  return kk_integer_from_int64(result, ctx);
}
