/*
 * log_bridge.c — one log line to stderr, flushed.
 *
 * Logs MUST go to stderr, not stdout: stdout is fully buffered when
 * redirected to a file (launchd's StandardOutPath, the e2e harness's
 * `> daemon.log 2>&1`), so a long-running daemon's log lines sit
 * invisible in the FILE* buffer until process exit. That made
 * daemon.log empty in production and failed the Caddy e2e's
 * `upload/done` log assertion. stderr is unbuffered by default; the
 * explicit fflush makes the guarantee unconditional.
 */
#include <stdio.h>
#include "aw_bridge.h"

kk_unit_t kk_aw_log_line(kk_string_t line, kk_context_t* ctx) {
  kk_ssize_t len = 0;
  const char* s = aw_cstr(line, &len, ctx);
  fwrite(s, 1, (size_t)len, stderr);
  fputc('\n', stderr);
  fflush(stderr);
  kk_string_drop(line, ctx);
  return kk_Unit;
}
