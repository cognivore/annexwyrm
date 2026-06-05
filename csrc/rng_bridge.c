/*
 * rng_bridge.c — /dev/urandom for cryptographic randomness.
 */
#include "annexwyrm.h"

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static int aw_read_urandom(uint8_t* out, size_t n) {
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, out + got, n - got);
    if (r <= 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    got += (size_t)r;
  }
  close(fd);
  return 0;
}

kk_string_t kk_aw_rand_bytes(kk_integer_t n_i, kk_context_t* ctx) {
  int64_t n = kk_integer_clamp64(n_i, ctx);
  if (n <= 0 || n > (1 << 20)) return aw_str_empty(ctx);
  uint8_t* buf = (uint8_t*)malloc((size_t)n);
  if (!buf) return aw_str_empty(ctx);
  if (aw_read_urandom(buf, (size_t)n) != 0) {
    free(buf);
    return aw_str_empty(ctx);
  }
  kk_string_t s = aw_str_from_bytes(buf, (size_t)n, ctx);
  free(buf);
  return s;
}

kk_string_t kk_aw_rand_hex(kk_integer_t n_i, kk_context_t* ctx) {
  int64_t n = kk_integer_clamp64(n_i, ctx);
  if (n <= 0 || n > (1 << 18)) return aw_str_empty(ctx);
  uint8_t* raw = (uint8_t*)malloc((size_t)n);
  if (!raw) return aw_str_empty(ctx);
  if (aw_read_urandom(raw, (size_t)n) != 0) {
    free(raw);
    return aw_str_empty(ctx);
  }
  char* hex = (char*)malloc((size_t)(n * 2 + 1));
  if (!hex) { free(raw); return aw_str_empty(ctx); }
  static const char digits[] = "0123456789abcdef";
  for (int64_t i = 0; i < n; ++i) {
    hex[2 * i]     = digits[(raw[i] >> 4) & 0x0F];
    hex[2 * i + 1] = digits[ raw[i]       & 0x0F];
  }
  hex[n * 2] = 0;
  kk_string_t s = aw_str_from_cstr(hex, ctx);
  free(raw);
  free(hex);
  return s;
}
