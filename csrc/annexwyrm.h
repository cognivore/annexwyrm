/*
 * annexwyrm.h — shared declarations for the C bridge.
 *
 * Every bridge file includes this. We use kklib's allocator throughout;
 * never return malloc'd buffers across the FFI boundary.
 */
#ifndef ANNEXWYRM_H
#define ANNEXWYRM_H

#include <kklib.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

/* Convenience: borrow a C string from a Koka string, get its length. */
static inline const char* aw_cstr(kk_string_t s, kk_ssize_t* len, kk_context_t* ctx) {
  return kk_string_cbuf_borrow(s, len, ctx);
}

/* Allocate a fresh Koka string from a (possibly non-NUL-terminated) byte
 * buffer. Suitable for binary data — we tell Koka it's "valid UTF-8" but
 * Koka strings are really just byte buffers under the hood, so binary
 * payloads round-trip cleanly as long as we never call Unicode-y
 * operations on them.
 */
static inline kk_string_t aw_str_from_bytes(const uint8_t* buf, size_t len, kk_context_t* ctx) {
  return kk_string_alloc_dupn_valid_utf8((kk_ssize_t)len, buf, ctx);
}

static inline kk_string_t aw_str_from_cstr(const char* s, kk_context_t* ctx) {
  return kk_string_alloc_dup_valid_utf8(s, ctx);
}

static inline kk_string_t aw_str_empty(kk_context_t* ctx) {
  return aw_str_from_cstr("", ctx);
}

#endif /* ANNEXWYRM_H */
