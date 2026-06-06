/*
 * proc_bridge.c — fork/exec subprocess runner.
 *
 * `argv` is the 0x1F-separated argv (`argv0\037arg1\037…`). Stdin is
 * piped into the child; stdout and stderr are captured. Returns
 * `"<exit>\037<stderr>\037<stdout>"`.
 *
 * STDOUT is the FINAL field because it is binary: `rclone cat` of an
 * archived blob yields raw PDF/JPEG/audio bytes, which contain 0x1F —
 * a mid-record stdout would truncate at the first one (silently
 * corrupting publish-later copies). The exit code and stderr are text;
 * stderr is copied with 0x1F stripped so it can never shift the frame.
 * Do NOT add fields after STDOUT.
 */
#include "aw_bridge.h"

#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>

static char** split_argv(const char* buf, size_t len, int* count_out) {
  /* Count separators. */
  int parts = 1;
  for (size_t i = 0; i < len; ++i) if (buf[i] == 0x1F) parts++;
  char** argv = (char**)calloc((size_t)parts + 1, sizeof(char*));
  if (!argv) return NULL;
  int idx = 0;
  size_t i = 0, start = 0;
  while (i <= len) {
    if (i == len || buf[i] == 0x1F) {
      size_t n = i - start;
      char* s = (char*)malloc(n + 1);
      if (!s) {
        for (int k = 0; k < idx; ++k) free(argv[k]);
        free(argv);
        return NULL;
      }
      memcpy(s, buf + start, n);
      s[n] = 0;
      argv[idx++] = s;
      start = i + 1;
    }
    ++i;
  }
  argv[idx] = NULL;
  if (count_out) *count_out = idx;
  return argv;
}

static void free_argv(char** argv) {
  if (!argv) return;
  for (int i = 0; argv[i]; ++i) free(argv[i]);
  free(argv);
}

struct buf { char* data; size_t len; size_t cap; };

static void buf_append(struct buf* b, const char* s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t newcap = b->cap ? b->cap * 2 : 4096;
    while (newcap < b->len + n + 1) newcap *= 2;
    char* nb = (char*)realloc(b->data, newcap);
    if (!nb) return;
    b->data = nb;
    b->cap  = newcap;
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
}

kk_string_t kk_aw_spawn(kk_string_t argv_s, kk_string_t stdin_s,
                         kk_context_t* ctx) {
  kk_ssize_t alen = 0, slen = 0;
  const char* a_buf = aw_cstr(argv_s, &alen, ctx);
  const char* s_buf = aw_cstr(stdin_s, &slen, ctx);

  int n_args = 0;
  char** argv = split_argv(a_buf, (size_t)alen, &n_args);
  if (!argv || n_args == 0) {
    kk_string_drop(argv_s, ctx);
    kk_string_drop(stdin_s, ctx);
    free_argv(argv);
    return aw_str_from_cstr("127\037spawn: empty argv\037", ctx);
  }

  int in_pipe[2], out_pipe[2], err_pipe[2];
  if (pipe(in_pipe) || pipe(out_pipe) || pipe(err_pipe)) {
    kk_string_drop(argv_s, ctx);
    kk_string_drop(stdin_s, ctx);
    free_argv(argv);
    return aw_str_from_cstr("127\037pipe failed\037", ctx);
  }

  pid_t pid = fork();
  if (pid < 0) {
    close(in_pipe[0]); close(in_pipe[1]);
    close(out_pipe[0]); close(out_pipe[1]);
    close(err_pipe[0]); close(err_pipe[1]);
    kk_string_drop(argv_s, ctx);
    kk_string_drop(stdin_s, ctx);
    free_argv(argv);
    return aw_str_from_cstr("127\037fork failed\037", ctx);
  }

  if (pid == 0) {
    /* child */
    dup2(in_pipe[0],  0);
    dup2(out_pipe[1], 1);
    dup2(err_pipe[1], 2);
    close(in_pipe[0]);  close(in_pipe[1]);
    close(out_pipe[0]); close(out_pipe[1]);
    close(err_pipe[0]); close(err_pipe[1]);
    execvp(argv[0], argv);
    _exit(127);
  }

  /* parent */
  close(in_pipe[0]);
  close(out_pipe[1]);
  close(err_pipe[1]);

  /* Write stdin (may block if child doesn't consume; for our use cases
   * — rclone rcat — that's expected.) */
  if (slen > 0) {
    ssize_t written = 0;
    while (written < (ssize_t)slen) {
      ssize_t w = write(in_pipe[1], s_buf + written, (size_t)slen - written);
      if (w <= 0) { if (errno == EINTR) continue; break; }
      written += w;
    }
  }
  close(in_pipe[1]);

  struct buf so = {0}, se = {0};
  char tmp[4096];
  /* Read both pipes in turn — simple poll loop. */
  fd_set rfds;
  int max_fd = (out_pipe[0] > err_pipe[0] ? out_pipe[0] : err_pipe[0]) + 1;
  int out_open = 1, err_open = 1;
  while (out_open || err_open) {
    FD_ZERO(&rfds);
    if (out_open) FD_SET(out_pipe[0], &rfds);
    if (err_open) FD_SET(err_pipe[0], &rfds);
    int sel = select(max_fd, &rfds, NULL, NULL, NULL);
    if (sel < 0) { if (errno == EINTR) continue; break; }
    if (out_open && FD_ISSET(out_pipe[0], &rfds)) {
      ssize_t r = read(out_pipe[0], tmp, sizeof(tmp));
      if (r > 0) buf_append(&so, tmp, (size_t)r);
      else { close(out_pipe[0]); out_open = 0; }
    }
    if (err_open && FD_ISSET(err_pipe[0], &rfds)) {
      ssize_t r = read(err_pipe[0], tmp, sizeof(tmp));
      if (r > 0) buf_append(&se, tmp, (size_t)r);
      else { close(err_pipe[0]); err_open = 0; }
    }
  }

  int status = 0;
  waitpid(pid, &status, 0);
  int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);

  char code_str[16];
  int cl = snprintf(code_str, sizeof(code_str), "%d", exit_code);

  /* EXIT \x1F STDERR \x1F STDOUT — stdout last because it is binary (see
   * the file header). stderr is diagnostics text; strip any 0x1F so it
   * can never shift the frame. */
  size_t total = (size_t)cl + 1 + se.len + 1 + so.len;
  char* result = (char*)malloc(total + 1);
  kk_string_t out_s;
  if (result) {
    memcpy(result, code_str, (size_t)cl);
    size_t pos = (size_t)cl;
    result[pos++] = 0x1F;
    for (size_t k = 0; k < se.len; ++k)
      if (se.data[k] != 0x1F) result[pos++] = se.data[k];
    result[pos++] = 0x1F;
    memcpy(result + pos, so.data, so.len); pos += so.len;
    out_s = aw_str_from_bytes((uint8_t*)result, pos, ctx);
    free(result);
  } else {
    out_s = aw_str_empty(ctx);
  }

  free(so.data);
  free(se.data);
  free_argv(argv);
  kk_string_drop(argv_s, ctx);
  kk_string_drop(stdin_s, ctx);
  return out_s;
}
