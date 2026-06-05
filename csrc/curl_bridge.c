/*
 * curl_bridge.c — libcurl easy interface for GET / POST.
 *
 * Returns "<status>\x1f<header-block>\x1f<body>". Network errors map
 * to status 0 with empty body. We never call curl_global_init from a
 * thread other than main; we lazily init once.
 */
#include "annexwyrm.h"

#include <curl/curl.h>
#include <pthread.h>

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;

static void global_init(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
}

struct buf {
  char* data;
  size_t len;
  size_t cap;
};

static size_t cb_write(char* ptr, size_t size, size_t nmemb, void* userdata) {
  struct buf* b = (struct buf*)userdata;
  size_t add = size * nmemb;
  if (b->len + add + 1 > b->cap) {
    size_t newcap = b->cap ? b->cap * 2 : 8192;
    while (newcap < b->len + add + 1) newcap *= 2;
    char* nb = (char*)realloc(b->data, newcap);
    if (!nb) return 0;
    b->data = nb;
    b->cap  = newcap;
  }
  memcpy(b->data + b->len, ptr, add);
  b->len += add;
  return add;
}

static size_t cb_header(char* ptr, size_t size, size_t nmemb, void* userdata) {
  return cb_write(ptr, size, nmemb, userdata);
}

/* Parse `\n`-separated `Name: value` lines into a `headers` blob the way
 * other bridges in this project use (`Name: value\n`). */
static struct curl_slist* build_request_headers(const char* raw, size_t len) {
  struct curl_slist* list = NULL;
  const char* p = raw;
  const char* end = raw + len;
  while (p < end) {
    const char* nl = p;
    while (nl < end && *nl != '\n') nl++;
    if (nl > p) {
      size_t n = (size_t)(nl - p);
      char* one = (char*)malloc(n + 1);
      if (one) {
        memcpy(one, p, n);
        one[n] = 0;
        list = curl_slist_append(list, one);
        free(one);
      }
    }
    p = nl + 1;
  }
  return list;
}

kk_string_t kk_aw_curl(kk_string_t method, kk_string_t url,
                        kk_string_t headers, kk_string_t body,
                        kk_context_t* ctx) {
  pthread_once(&g_init_once, global_init);

  kk_ssize_t mlen = 0, ulen = 0, hlen = 0, blen = 0;
  const char* m = aw_cstr(method,  &mlen, ctx);
  const char* u = aw_cstr(url,     &ulen, ctx);
  const char* h = aw_cstr(headers, &hlen, ctx);
  const char* b = aw_cstr(body,    &blen, ctx);

  CURL* curl = curl_easy_init();
  long status = 0;
  struct buf body_buf  = {0};
  struct buf hdr_buf   = {0};

  if (curl) {
    curl_easy_setopt(curl, CURLOPT_URL, u);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "annexwyrm/0.1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, cb_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body_buf);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, cb_header);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &hdr_buf);

    if (strcmp(m, "POST") == 0) {
      curl_easy_setopt(curl, CURLOPT_POST, 1L);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, b);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)blen);
    }

    struct curl_slist* hlist = build_request_headers(h, (size_t)hlen);
    if (hlist) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hlist);

    CURLcode rc = curl_easy_perform(curl);
    if (rc == CURLE_OK) {
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    }
    if (hlist) curl_slist_free_all(hlist);
    curl_easy_cleanup(curl);
  }

  /* Stitch together the result. */
  char status_str[16];
  int sl = snprintf(status_str, sizeof(status_str), "%ld", status);

  size_t total = (size_t)sl + 1 + hdr_buf.len + 1 + body_buf.len;
  char* out = (char*)malloc(total + 1);
  kk_string_t result;
  if (out) {
    memcpy(out, status_str, (size_t)sl);
    size_t pos = (size_t)sl;
    out[pos++] = 0x1F;
    if (hdr_buf.len) { memcpy(out + pos, hdr_buf.data, hdr_buf.len); pos += hdr_buf.len; }
    out[pos++] = 0x1F;
    if (body_buf.len) { memcpy(out + pos, body_buf.data, body_buf.len); pos += body_buf.len; }
    result = aw_str_from_bytes((uint8_t*)out, pos, ctx);
    free(out);
  } else {
    result = aw_str_empty(ctx);
  }

  free(body_buf.data);
  free(hdr_buf.data);

  kk_string_drop(method, ctx);
  kk_string_drop(url, ctx);
  kk_string_drop(headers, ctx);
  kk_string_drop(body, ctx);
  return result;
}
