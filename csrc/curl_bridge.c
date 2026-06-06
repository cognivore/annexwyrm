/*
 * curl_bridge.c — libcurl easy interface for GET / POST.
 *
 * Returns "<status>\x1f<header-block>\x1f<body>". Network errors map
 * to status 0 with empty body. We never call curl_global_init from a
 * thread other than main; we lazily init once.
 */
#include "aw_bridge.h"

#include <curl/curl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;

static void global_init(void) {
  curl_global_init(CURL_GLOBAL_DEFAULT);
}

/* Response-body / header cap. The daemon fetches remote actor documents and
 * delivers to remote inboxes; a hostile peer must not be able to make us
 * buffer an unbounded (or never-ending until timeout) response into RAM.
 * 8 MiB is far larger than any real actor JSON. */
#define MAX_CURL_RESP_BYTES (8 * 1024 * 1024)

struct buf {
  char* data;
  size_t len;
  size_t cap;
};

static size_t cb_write(char* ptr, size_t size, size_t nmemb, void* userdata) {
  struct buf* b = (struct buf*)userdata;
  size_t add = size * nmemb;
  /* Refuse to grow past the cap — returning a short count aborts the
   * transfer (CURLE_WRITE_ERROR), bounding memory from a hostile remote. */
  if (b->len + add + 1 > MAX_CURL_RESP_BYTES) return 0;
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

/* SSRF guard: reject connections to private / loopback / link-local /
 * unspecified addresses. The daemon's egress is driven by attacker-supplied
 * URLs (a remote keyId, a cached actor inbox), so without this a peer could
 * point us at 127.0.0.1, 169.254.169.254 (cloud metadata), or RFC1918 hosts.
 * This runs AFTER curl resolves the name, so it also defeats DNS rebinding.
 * Returning CURL_SOCKOPT_ERROR aborts the connection. */
static int is_blocked_v4(uint32_t a /* host byte order */) {
  uint8_t b0 = (a >> 24) & 0xff, b1 = (a >> 16) & 0xff;
  if (b0 == 127) return 1;                 /* 127.0.0.0/8 loopback */
  if (b0 == 10) return 1;                  /* 10.0.0.0/8 */
  if (b0 == 0) return 1;                   /* 0.0.0.0/8 unspecified */
  if (b0 == 169 && b1 == 254) return 1;    /* 169.254.0.0/16 link-local (IMDS) */
  if (b0 == 172 && (b1 >= 16 && b1 <= 31)) return 1; /* 172.16.0.0/12 */
  if (b0 == 192 && b1 == 168) return 1;    /* 192.168.0.0/16 */
  if (b0 == 100 && (b1 >= 64 && b1 <= 127)) return 1; /* 100.64.0.0/10 CGNAT */
  if (b0 >= 224) return 1;                 /* 224.0.0.0/4 multicast + 240/4 */
  return 0;
}

/* Test-only escape hatch: the local two-instance federation e2e runs both
 * peers on 127.0.0.1, which the SSRF guard would (correctly, for prod)
 * block. ANNEXWYRM_ALLOW_PRIVATE_EGRESS=1 disables the private-range block.
 * NEVER set this in production — prod peers are public IPs and the only
 * local listener is the unix socket (not reached via curl). Default: block. */
static int allow_private_egress(void) {
  const char* v = getenv("ANNEXWYRM_ALLOW_PRIVATE_EGRESS");
  return v && v[0] == '1';
}

/* True if curl is about to connect to a private/loopback/link-local addr. */
static int addr_is_blocked(int family, const struct sockaddr* sa) {
  if (family == AF_INET) {
    const struct sockaddr_in* s4 = (const struct sockaddr_in*)sa;
    return is_blocked_v4(ntohl(s4->sin_addr.s_addr));
  } else if (family == AF_INET6) {
    const struct sockaddr_in6* s6 = (const struct sockaddr_in6*)sa;
    const uint8_t* a = s6->sin6_addr.s6_addr;
    int all_zero_but_last = 1;
    for (int i = 0; i < 15; ++i) if (a[i]) { all_zero_but_last = 0; break; }
    if (all_zero_but_last && (a[15] == 1 || a[15] == 0)) return 1; /* ::1 / :: */
    if (a[0] == 0xfe && (a[1] & 0xc0) == 0x80) return 1;           /* fe80::/10 */
    if ((a[0] & 0xfe) == 0xfc) return 1;                            /* fc00::/7 */
    if (a[10] == 0xff && a[11] == 0xff) {                           /* ::ffff:v4 */
      uint32_t v4 = ((uint32_t)a[12] << 24) | ((uint32_t)a[13] << 16) |
                    ((uint32_t)a[14] << 8) | a[15];
      return is_blocked_v4(v4);
    }
    return 0;
  }
  return 1;  /* unknown family: refuse */
}

/* SSRF guard, done at the RIGHT hook: CURLOPT_OPENSOCKETFUNCTION is called
 * with the address curl resolved and is about to connect to (so it also
 * defeats DNS rebinding), and WE create the socket. The earlier attempt used
 * CURLOPT_SOCKOPTFUNCTION + getpeername, which fires before connect() — the
 * socket isn't connected yet, getpeername returns ENOTCONN, and EVERY egress
 * was aborted (status 0). That silently broke all federation on prod (remote
 * actor fetch failed → inbound Follows rejected as unsigned). The e2e masked
 * it because ALLOW_PRIVATE_EGRESS short-circuits the check. */
static curl_socket_t opensocket_cb(void* clientp, curlsocktype purpose,
                                   struct curl_sockaddr* addr) {
  (void)clientp;
  if (purpose == CURLSOCKTYPE_IPCXN && !allow_private_egress() &&
      addr_is_blocked(addr->family, &addr->addr)) {
    return CURL_SOCKET_BAD;  /* refuse the connection */
  }
  return socket(addr->family, addr->socktype, addr->protocol);
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
    /* SSRF hardening: only HTTP/HTTPS (no file://, gopher://, dict://, …),
     * and reject private/loopback/link-local targets post-resolution. */
#ifdef CURLOPT_PROTOCOLS_STR
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
#else
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
#endif
    curl_easy_setopt(curl, CURLOPT_OPENSOCKETFUNCTION, opensocket_cb);
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
    /* Response headers come from an UNTRUSTED remote: strip 0x1F so a
     * hostile peer can never shift the frame. The body is last and raw —
     * the Koka side decodes with split-limit, so it may contain 0x1F. */
    for (size_t k = 0; k < hdr_buf.len; ++k)
      if (hdr_buf.data[k] != 0x1F) out[pos++] = hdr_buf.data[k];
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
