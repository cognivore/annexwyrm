// annexwyrm/interp/time_real — Time → host clock via C bridge.

module interp/time_real

import effects/time

// Three C primitives. All return their result by value (we always have
// enough memory; the strings are < 64 bytes). See `csrc/time_bridge.c`.
extern import
  c file "../../csrc/time_bridge.c"

extern kk-now-iso() : ndet string
  c "kk_aw_now_iso"

extern kk-now-http() : ndet string
  c "kk_aw_now_http"

extern kk-now-unix() : ndet int
  c "kk_aw_now_unix"

// param is `epoch`, not `unix`: gcc predefines the macro `unix`=1 on Linux,
// turning a C parameter named `unix` into `int 1` (build error). See
// effects/time.kk.
extern kk-iso-from-unix( epoch : int ) : ndet string
  c "kk_aw_iso_from_unix"

pub fun with-real-time( action : () -> <time,ndet|e> a ) : <ndet|e> a
  with handler
    fun now-iso()             kk-now-iso()
    fun now-http()            kk-now-http()
    fun now-unix()            kk-now-unix()
    fun iso-from-unix(u : int) kk-iso-from-unix(u)
  action()
