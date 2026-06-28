/*
 * fs_bridge.c — write a private (0600) file, atomically.
 *
 * The ONE filesystem-write primitive in annexwyrm. It exists so a tenant's
 * rclone config (which carries cloud-provider secrets) can be materialised to
 * disk for `rclone --config <path>` WITHOUT the secrets ever touching argv or
 * the process environment (both readable by other processes). The file is
 * created mode 0600 in a 0700 parent directory, and replaced atomically via
 * rename(2) so a concurrent reader never sees a half-written config.
 *
 * Returns 0 on success, -1 on any failure (the Koka caller treats <0 as
 * "could not materialise" and falls back to the ambient config / fails the op).
 */
#include "aw_bridge.h"

#include <stdio.h>      /* snprintf */
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

/* Recursively create every component of `dir` with mode 0700. Existing
 * components (EEXIST) are fine. Returns 0 on success. `dir` is mutated in
 * place transiently (separators temporarily NUL'd) then restored. */
static int aw_mkdirs(char* dir) {
  if (!dir || !*dir) return 0;
  for (char* p = dir + 1; *p; ++p) {
    if (*p == '/') {
      *p = 0;
      if (mkdir(dir, 0700) != 0 && errno != EEXIST) { *p = '/'; return -1; }
      *p = '/';
    }
  }
  if (mkdir(dir, 0700) != 0 && errno != EEXIST) return -1;
  return 0;
}

/* Write all of `buf` to fd, retrying short writes / EINTR. */
static int aw_write_all(int fd, const char* buf, size_t len) {
  size_t off = 0;
  while (off < len) {
    ssize_t w = write(fd, buf + off, len - off);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    off += (size_t)w;
  }
  return 0;
}

kk_integer_t kk_aw_write_private_file(kk_string_t path_s, kk_string_t bytes_s,
                                      kk_context_t* ctx) {
  kk_ssize_t plen = 0, blen = 0;
  const char* path = aw_cstr(path_s, &plen, ctx);
  const char* bytes = aw_cstr(bytes_s, &blen, ctx);
  int rc = -1;

  /* Copy the path to a writable C string (aw_cstr borrows a const buffer). */
  char* pbuf = (char*)malloc((size_t)plen + 1);
  if (pbuf) {
    memcpy(pbuf, path, (size_t)plen);
    pbuf[plen] = 0;

    /* Create the parent directory tree (0700). Find the last '/'. */
    char* slash = NULL;
    for (char* q = pbuf; *q; ++q) if (*q == '/') slash = q;
    int dirs_ok = 1;
    if (slash && slash != pbuf) {
      *slash = 0;
      if (aw_mkdirs(pbuf) != 0) dirs_ok = 0;
      *slash = '/';
    }

    if (dirs_ok) {
      /* Atomic replace: write to "<path>.tmpXXXXXX" (0600 via mkstemp) then
       * rename over the target. */
      size_t tlen = (size_t)plen + 12;
      char* tmpl = (char*)malloc(tlen + 1);
      if (tmpl) {
        snprintf(tmpl, tlen + 1, "%s.tmpXXXXXX", pbuf);
        int fd = mkstemp(tmpl);
        if (fd >= 0) {
          /* mkstemp already creates 0600 on modern libc; pin it explicitly. */
          fchmod(fd, 0600);
          int ok = (aw_write_all(fd, bytes, (size_t)blen) == 0);
          if (ok) ok = (fsync(fd) == 0) || (errno == EINVAL); /* EINVAL: fd is not fsync-able */
          close(fd);
          if (ok && rename(tmpl, pbuf) == 0) rc = 0;
          else unlink(tmpl);
        }
        free(tmpl);
      }
    }
    free(pbuf);
  }

  kk_string_drop(path_s, ctx);
  kk_string_drop(bytes_s, ctx);
  return kk_integer_from_int(rc, ctx);
}
