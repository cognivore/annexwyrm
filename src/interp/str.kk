// annexwyrm/interp/str — helpers backed by the C bridge.
//
// `byte-count` returns the byte length, not the codepoint count, which
// we need for HTTP Content-Length.

module interp/str

extern import
  c file "../../csrc/str_bridge.c"

pub extern byte-count( s : string ) : total int
  c "kk_aw_str_bytes"

// Split into exactly `n` leading fields plus the verbatim remainder.
//
// This is THE decoder for every \x1f-framed bridge record that carries one
// binary field: the binary field must be LAST, because any real PDF/JPEG/
// audio payload contains 0x1F bytes (≈1 per 256) and a plain split("\x1f")
// silently truncates it — exactly how the first real phone upload broke.
// The remainder's interior splits are rejoined byte-exact. Returns Nothing
// if there are fewer than `n` separators.
pub fun split-limit( s : string, sep : string, n : int ) : maybe<(list<string>, string)>
  val parts = s.split(sep)
  if parts.length < n + 1 then Nothing
  else Just((parts.take(n), parts.drop(n).join(sep)))
