// annexwyrm/interp/crypto_openssl — Crypto → OpenSSL via C bridge.

module interp/crypto_openssl

import effects/crypto

extern import
  c file "../../csrc/crypto_bridge.c"

extern kk-sha256( input : string ) : ndet string
  c "kk_aw_sha256"

extern kk-rsa-sign( priv-pem : string, msg : string ) : ndet string
  c "kk_aw_rsa_sign"

extern kk-rsa-verify( pubkey-pem : string, msg : string, sig : string ) : ndet int
  c "kk_aw_rsa_verify"

extern kk-rsa-keygen() : ndet string
  c "kk_aw_rsa_keygen"     // returns "<priv>\x1f<pubkey>"

extern kk-b64-encode( bytes : string ) : ndet string
  c "kk_aw_b64_encode"

extern kk-b64-decode-or-empty( b64 : string ) : ndet string
  c "kk_aw_b64_decode"     // returns "" on failure

extern kk-argon2id-hash( password : string ) : ndet string
  c "kk_aw_argon2id_hash"

extern kk-argon2id-verify( phc : string, password : string ) : ndet int
  c "kk_aw_argon2id_verify"

pub fun with-openssl-crypto( action : () -> <crypto,ndet|e> a ) : <ndet|e> a
  with handler
    fun sha256(b : string)                       kk-sha256(b)
    fun rsa-sign-sha256(priv : string, msg : string) kk-rsa-sign(priv, msg)
    fun rsa-verify-sha256(pubkey-pem : string, msg : string, sig : string)
      kk-rsa-verify(pubkey-pem, msg, sig) != 0
    fun rsa-keygen() split-keypair(kk-rsa-keygen())
    fun b64-encode(b : string)  kk-b64-encode(b)
    fun b64-decode(s : string)  decode-or-nothing(kk-b64-decode-or-empty(s))
    fun argon2id-hash(p : string)                  kk-argon2id-hash(p)
    fun argon2id-verify(phc : string, p : string)  kk-argon2id-verify(phc, p) != 0
  action()

fun split-keypair( joined : string ) : (string,string)
  match joined.split("\x1f")
    Cons(priv, Cons(pubkey, _)) -> (priv, pubkey)
    _ -> ("", "")

fun decode-or-nothing( out : string ) : maybe<string>
  if out == "" then Nothing else Just(out)
