// annexwyrm/interp/rng_urandom — Rng → /dev/urandom via C bridge.

module interp/rng_urandom

import effects/rng

extern import
  c file "../../csrc/rng_bridge.c"

extern kk-rand-bytes( n : int ) : ndet string
  c "kk_aw_rand_bytes"

extern kk-rand-hex( n : int ) : ndet string
  c "kk_aw_rand_hex"

pub fun with-urandom-rng( action : () -> <rng,ndet|e> a ) : <ndet|e> a
  with handler
    fun rand-bytes(n : int) kk-rand-bytes(n)
    fun rand-hex(n : int)   kk-rand-hex(n)
  action()
