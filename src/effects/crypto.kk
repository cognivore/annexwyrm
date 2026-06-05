// annexwyrm/effects/crypto — primitive cryptography.
//
// These are the building blocks that the HTTP-signing algorithm in
// `ap/sign` uses. We keep them at the primitive level (raw byte buffers,
// PEM strings) so the algorithm layer can choose canonicalisation.

module effects/crypto

pub effect crypto
  // SHA-256 of arbitrary bytes; returns the raw 32-byte digest packed
  // into a string.
  fun sha256( bytes : string ) : string

  // RSA-PKCS#1 v1.5 sign of `msg` using the SHA-256 hash. Returns the
  // raw signature bytes (modulus-length, i.e. 256 bytes for RSA-2048).
  fun rsa-sign-sha256( priv-pem : string, msg : string ) : string

  // RSA-PKCS#1 v1.5 verify of `sig` over `msg`. True iff the signature
  // is valid under `pub-pem`.
  fun rsa-verify-sha256( pubkey-pem : string, msg : string, sig : string ) : bool

  // Generate a fresh RSA-2048 keypair. Returns (private-PEM, public-PEM).
  fun rsa-keygen() : (string,string)

  // Base64 (standard alphabet, `=` padding) of arbitrary bytes.
  fun b64-encode( bytes : string ) : string

  // Decode a base64 string. Returns Nothing on malformed input.
  fun b64-decode( b64 : string ) : maybe<string>

  // Argon2id password hash. Returns a PHC string suitable for storage.
  // Cost parameters are decided by the interpreter.
  fun argon2id-hash( password : string ) : string

  // Verify a password against a previously stored PHC hash.
  fun argon2id-verify( phc : string, password : string ) : bool

// ----------------------------------------------------------------------
//  Pure helpers built atop the effect.
// ----------------------------------------------------------------------

// SHA-256 of `bytes`, base64-encoded, prefixed with "SHA-256=".  This is
// the exact form of the HTTP `Digest:` header.
pub fun http-digest( bytes : string ) : crypto string
  "SHA-256=" ++ b64-encode(sha256(bytes))
