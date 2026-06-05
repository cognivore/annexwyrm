// annexwyrm/interp/str — helpers backed by the C bridge.
//
// `byte-count` returns the byte length, not the codepoint count, which
// we need for HTTP Content-Length.

module interp/str

extern import
  c file "../../csrc/str_bridge.c"

pub extern byte-count( s : string ) : total int
  c "kk_aw_str_bytes"
