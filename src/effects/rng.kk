// annexwyrm/effects/rng — cryptographically secure random.
//
// We use this for IDs (session tokens, activity ids, item slugs) and
// nonces. The production interpreter reads from /dev/urandom; tests
// install a counter.

module effects/rng

pub effect rng
  // Return `n` raw random bytes packed into a string. Bytes may be any
  // value 0..255 inclusive; treat the string as a byte buffer, not text.
  fun rand-bytes( n : int ) : string

  // Return `n` lowercase hex digits (so `n` bytes of entropy yields
  // 2*n characters). Suitable for URL-safe identifiers.
  fun rand-hex( n : int ) : string
