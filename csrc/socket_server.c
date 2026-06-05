/*
 * socket_server.c — Unix-socket HTTP/1.1 server.
 *
 * Caddy reverse-proxies into us; we don't speak TLS, ALPN, or h2 — just
 * HTTP/1.1 over the local socket. We implement just enough HTTP to
 * forward a parsed request into Koka and write back its response.
 *
 * The Koka side calls:
 *   kk_aw_listen(path)               -> fd (or -1)
 *   kk_aw_accept(fd)                 -> conn fd (or -1)
 *   kk_aw_read_request(conn)         -> encoded request string
 *   kk_aw_write_response(conn, raw)  -> bytes written
 *   kk_aw_close(fd)                  -> ()
 *
 * Request encoding (records separated by 0x1F):
 *   METHOD PATH QUERY HEADERS BODY REMOTE
 * HEADERS is `name: value\n…`.
 */
#include "aw_bridge.h"

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <poll.h>

#define MAX_REQ_BYTES (16 * 1024 * 1024)   /* 16 MiB cap; mirrors Caddy's cap. */

kk_integer_t kk_aw_listen(kk_string_t path, kk_context_t* ctx) {
  /* Ignore SIGPIPE so a peer closing mid-write (`nc -z` probe,
   * abandoned curl, etc.) doesn't kill the daemon. */
  signal(SIGPIPE, SIG_IGN);

  kk_ssize_t plen = 0;
  const char* p = aw_cstr(path, &plen, ctx);
  unlink(p);   /* remove stale socket from a previous run */
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) { kk_string_drop(path, ctx); return kk_integer_from_int(-1, ctx); }
  struct sockaddr_un addr = {0};
  addr.sun_family = AF_UNIX;
  /* leave room for NUL */
  size_t n = (size_t)plen < sizeof(addr.sun_path) - 1
             ? (size_t)plen : sizeof(addr.sun_path) - 1;
  memcpy(addr.sun_path, p, n);
  addr.sun_path[n] = 0;
  if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
      listen(fd, 64) < 0) {
    close(fd);
    kk_string_drop(path, ctx);
    return kk_integer_from_int(-1, ctx);
  }
  /* Make the socket world-accessible (Caddy is typically a different user). */
  chmod(p, 0666);
  kk_string_drop(path, ctx);
  return kk_integer_from_int(fd, ctx);
}

kk_integer_t kk_aw_accept(kk_integer_t fd_i, kk_context_t* ctx) {
  int fd = (int)kk_integer_clamp32(fd_i, ctx);
  int conn = accept(fd, NULL, NULL);
  return kk_integer_from_int(conn, ctx);
}

/* Like kk_aw_accept, but bounded by `timeout_ms`. We poll() the listen
 * fd so an idle daemon can return control to Koka and fire its periodic
 * tick instead of blocking in accept() forever.
 *
 * Returns:
 *    >= 0  the accepted connection fd
 *    -2    timeout elapsed with no incoming connection (tick opportunity)
 *    -1    an unrecoverable error
 *
 * EINTR handling: a signal interrupting poll() is treated as a timeout
 * (return -2), NOT a retry. Rationale — the caller's loop already
 * recurses after a -2 by running the tick and polling again, so a
 * spurious early wakeup costs at most one extra (cheap) tick + re-poll
 * and never loses a connection. Retrying in C instead would risk a
 * subtle busy-loop if a signal kept firing, and would also reset the
 * remaining timeout. Treating EINTR as "just tick early" keeps the
 * timing semantics simple and the loop liveness obvious.
 *
 * No fd is leaked: poll() opens nothing, and we only accept() once we
 * know the listen fd is readable. If that accept() itself fails we
 * return -1 without having created a descriptor. */
kk_integer_t kk_aw_accept_timeout(kk_integer_t fd_i, kk_integer_t timeout_ms_i,
                                  kk_context_t* ctx) {
  int fd = (int)kk_integer_clamp32(fd_i, ctx);
  int timeout_ms = (int)kk_integer_clamp32(timeout_ms_i, ctx);

  struct pollfd pfd;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;

  int pr = poll(&pfd, 1, timeout_ms);
  if (pr == 0) {
    /* timeout: nothing to accept */
    return kk_integer_from_int(-2, ctx);
  }
  if (pr < 0) {
    /* EINTR -> treat as a timeout (tick early, then re-poll); any other
     * poll error is unrecoverable. */
    if (errno == EINTR) return kk_integer_from_int(-2, ctx);
    return kk_integer_from_int(-1, ctx);
  }
  /* Readable (or an error condition surfaced via revents). Attempt the
   * accept; reuse the same logic as kk_aw_accept. A signal or a peer that
   * reset between poll() and accept() shows up as a *transient* errno —
   * forwarding those as -1 would stop the whole serve loop (kill the
   * daemon) over a benign hiccup, and poll-then-accept widens that race
   * window. Treat the transient set as -2 ("tick early, then re-poll");
   * only a genuinely unrecoverable accept() error is -1. */
  int conn = accept(fd, NULL, NULL);
  if (conn < 0) {
    if (errno == EINTR || errno == ECONNABORTED ||
        errno == EAGAIN || errno == EWOULDBLOCK)
      return kk_integer_from_int(-2, ctx);
    return kk_integer_from_int(-1, ctx);
  }
  return kk_integer_from_int(conn, ctx);
}

kk_unit_t kk_aw_close(kk_integer_t fd_i, kk_context_t* ctx) {
  int fd = (int)kk_integer_clamp32(fd_i, ctx);
  if (fd >= 0) close(fd);
  return kk_Unit;
}

/* Read until the buffer contains "\r\n\r\n"; returns offset just past
 * that sequence, or -1 on error/EOF without finding it. */
static ssize_t read_until_double_crlf(int fd, char** buf, size_t* len, size_t* cap) {
  while (1) {
    if (*len + 4096 > *cap) {
      size_t newcap = *cap ? *cap * 2 : 8192;
      if (newcap > MAX_REQ_BYTES) return -1;
      char* nb = (char*)realloc(*buf, newcap);
      if (!nb) return -1;
      *buf = nb;
      *cap = newcap;
    }
    ssize_t r = read(fd, *buf + *len, *cap - *len);
    if (r <= 0) {
      if (r < 0 && errno == EINTR) continue;
      return -1;
    }
    *len += (size_t)r;
    /* Look for \r\n\r\n at the tail. */
    if (*len >= 4) {
      const char* p = *buf;
      for (size_t i = 0; i + 3 < *len; ++i) {
        if (p[i] == '\r' && p[i+1] == '\n' && p[i+2] == '\r' && p[i+3] == '\n') {
          return (ssize_t)(i + 4);
        }
      }
    }
    if (*len >= MAX_REQ_BYTES) return -1;
  }
}

static int read_n_more(int fd, char** buf, size_t* len, size_t* cap, size_t needed) {
  while (*len < needed) {
    if (needed > *cap) {
      size_t newcap = *cap;
      if (newcap == 0) newcap = 8192;
      while (newcap < needed) newcap *= 2;
      if (newcap > MAX_REQ_BYTES) return 0;
      char* nb = (char*)realloc(*buf, newcap);
      if (!nb) return 0;
      *buf = nb;
      *cap = newcap;
    }
    ssize_t r = read(fd, *buf + *len, needed - *len);
    if (r <= 0) {
      if (r < 0 && errno == EINTR) continue;
      return 0;
    }
    *len += (size_t)r;
  }
  return 1;
}

/* Find a header by name (case-insensitive) within the header block.
 * The header block is the bytes between the start-line and the blank
 * line, with CRLF line endings.  Returns the value pointer + length
 * via out params; returns 0 if absent. */
static int find_header(const char* hdrs, size_t hlen,
                       const char* name, size_t name_len,
                       const char** val_out, size_t* val_len_out) {
  const char* p = hdrs;
  const char* end = hdrs + hlen;
  while (p < end) {
    const char* eol = memchr(p, '\n', (size_t)(end - p));
    if (!eol) eol = end;
    const char* colon = memchr(p, ':', (size_t)(eol - p));
    if (colon && (size_t)(colon - p) == name_len) {
      int match = 1;
      for (size_t i = 0; i < name_len; ++i) {
        char a = p[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
        if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
        if (a != b) { match = 0; break; }
      }
      if (match) {
        const char* v = colon + 1;
        while (v < eol && (*v == ' ' || *v == '\t')) v++;
        const char* ve = eol;
        if (ve > v && ve[-1] == '\r') ve--;
        *val_out = v;
        *val_len_out = (size_t)(ve - v);
        return 1;
      }
    }
    p = eol + 1;
  }
  return 0;
}

/* Encode the parsed request into one Koka string.
 * Layout:  METHOD \x1F PATH \x1F QUERY \x1F HEADERS \x1F BODY \x1F REMOTE
 * HEADERS is `name: value\n` per line.
 */
kk_string_t kk_aw_read_request(kk_integer_t conn_i, kk_context_t* ctx) {
  int conn = (int)kk_integer_clamp32(conn_i, ctx);
  if (conn < 0) return aw_str_empty(ctx);

  char* buf = NULL;
  size_t len = 0, cap = 0;
  ssize_t hdr_end = read_until_double_crlf(conn, &buf, &len, &cap);
  if (hdr_end < 0) { free(buf); return aw_str_empty(ctx); }

  /* Parse start line: METHOD SP TARGET SP VERSION CRLF */
  size_t i = 0;
  while (i < (size_t)hdr_end && buf[i] != ' ' && buf[i] != '\r') i++;
  size_t m_start = 0, m_end = i;
  while (i < (size_t)hdr_end && buf[i] == ' ') i++;
  size_t t_start = i;
  while (i < (size_t)hdr_end && buf[i] != ' ' && buf[i] != '\r') i++;
  size_t t_end = i;
  /* Find end of start line. */
  while (i < (size_t)hdr_end && buf[i] != '\n') i++;
  size_t sl_end = (i < (size_t)hdr_end) ? i + 1 : i;

  /* Split TARGET into PATH and QUERY at '?'. */
  size_t p_start = t_start, p_end = t_end, q_start = t_end, q_end = t_end;
  for (size_t k = t_start; k < t_end; ++k) {
    if (buf[k] == '?') { p_end = k; q_start = k + 1; break; }
  }

  /* Headers: from sl_end to hdr_end - 2 ( minus the trailing \r\n).
   * Within HEADER_BLOCK we use the original CRLFs verbatim. */
  size_t h_start = sl_end;
  size_t h_end   = (size_t)hdr_end >= 2 ? (size_t)hdr_end - 2 : (size_t)hdr_end;

  /* Optional body. We honour Content-Length only; chunked encoding is
   * not expected from Caddy. */
  size_t body_offset = (size_t)hdr_end;
  size_t body_len = 0;
  const char* cl_val = NULL;
  size_t cl_val_len = 0;
  if (find_header(buf + h_start, h_end - h_start,
                  "Content-Length", 14, &cl_val, &cl_val_len)) {
    char tmp[32] = {0};
    if (cl_val_len < sizeof(tmp)) {
      memcpy(tmp, cl_val, cl_val_len);
      long long n = strtoll(tmp, NULL, 10);
      if (n > 0 && n <= MAX_REQ_BYTES) body_len = (size_t)n;
    }
  }
  if (body_len > 0) {
    if (!read_n_more(conn, &buf, &len, &cap, body_offset + body_len)) {
      free(buf);
      return aw_str_empty(ctx);
    }
  }

  /* Build encoded record. */
  size_t total = (m_end - m_start) + 1
               + (p_end - p_start) + 1
               + (q_end - q_start) + 1
               + (h_end - h_start) + 1
               + body_len + 1
               + 0 /* remote */;
  char* out = (char*)malloc(total + 1);
  if (!out) { free(buf); return aw_str_empty(ctx); }
  size_t pos = 0;
  memcpy(out + pos, buf + m_start, m_end - m_start); pos += (m_end - m_start);
  out[pos++] = 0x1F;
  memcpy(out + pos, buf + p_start, p_end - p_start); pos += (p_end - p_start);
  out[pos++] = 0x1F;
  memcpy(out + pos, buf + q_start, q_end - q_start); pos += (q_end - q_start);
  out[pos++] = 0x1F;
  memcpy(out + pos, buf + h_start, h_end - h_start); pos += (h_end - h_start);
  out[pos++] = 0x1F;
  if (body_len) {
    memcpy(out + pos, buf + body_offset, body_len);
    pos += body_len;
  }
  out[pos++] = 0x1F;
  /* remote left empty (Caddy puts X-Forwarded-For in headers anyway) */

  kk_string_t result = aw_str_from_bytes((uint8_t*)out, pos, ctx);
  free(out);
  free(buf);
  return result;
}

/* Response encoding: caller pre-formats the HTTP/1.1 response in Koka
 * and hands us raw bytes to write. */
kk_integer_t kk_aw_write_response(kk_integer_t conn_i, kk_string_t raw,
                                   kk_context_t* ctx) {
  int conn = (int)kk_integer_clamp32(conn_i, ctx);
  kk_ssize_t blen = 0;
  const char* b = aw_cstr(raw, &blen, ctx);
  size_t total = 0;
  if (conn >= 0 && blen > 0) {
    size_t written = 0;
    while (written < (size_t)blen) {
      ssize_t w = write(conn, b + written, (size_t)blen - written);
      if (w <= 0) {
        if (errno == EINTR) continue;
        break;
      }
      written += (size_t)w;
    }
    total = written;
  }
  kk_string_drop(raw, ctx);
  return kk_integer_from_int((kk_intf_t)total, ctx);
}
