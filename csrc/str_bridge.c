/*
 * str_bridge.c — small string utilities the Koka stdlib doesn't expose.
 */
#include "annexwyrm.h"

/* Byte length of a Koka string. (Koka exposes chars/count which is
 * the code-point count; we need bytes for HTTP Content-Length.) */
kk_integer_t kk_aw_str_bytes(kk_string_t s, kk_context_t* ctx) {
  kk_ssize_t len = 0;
  aw_cstr(s, &len, ctx);
  kk_string_drop(s, ctx);
  return kk_integer_from_int((kk_intf_t)len, ctx);
}
