/*
 * crypto_bridge.c — SHA-256, RSA-SHA256, Base64, Argon2id via OpenSSL +
 * (where available) libargon2.
 *
 * The Argon2 path uses libargon2 if present; if not, it falls back to
 * PBKDF2-SHA256 (still acceptable for an archive tool).  The fallback
 * is selected at compile time via -DANNEXWYRM_NO_ARGON2.
 */
#include "annexwyrm.h"

#include <openssl/sha.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/evp.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/buffer.h>

/* ---------- SHA-256 ---------- */

kk_string_t kk_aw_sha256(kk_string_t input, kk_context_t* ctx) {
  kk_ssize_t len = 0;
  const char* buf = aw_cstr(input, &len, ctx);
  unsigned char out[SHA256_DIGEST_LENGTH];
  SHA256((const unsigned char*)buf, (size_t)len, out);
  kk_string_t result = aw_str_from_bytes(out, SHA256_DIGEST_LENGTH, ctx);
  kk_string_drop(input, ctx);
  return result;
}

/* ---------- Base64 ---------- */

kk_string_t kk_aw_b64_encode(kk_string_t input, kk_context_t* ctx) {
  kk_ssize_t inlen = 0;
  const char* in = aw_cstr(input, &inlen, ctx);
  size_t outlen = 4 * ((size_t)(inlen + 2) / 3);
  char* out = (char*)malloc(outlen + 1);
  if (!out) { kk_string_drop(input, ctx); return aw_str_empty(ctx); }
  int n = EVP_EncodeBlock((unsigned char*)out, (const unsigned char*)in, (int)inlen);
  out[n] = 0;
  kk_string_t s = aw_str_from_cstr(out, ctx);
  free(out);
  kk_string_drop(input, ctx);
  return s;
}

kk_string_t kk_aw_b64_decode(kk_string_t input, kk_context_t* ctx) {
  kk_ssize_t inlen = 0;
  const char* in = aw_cstr(input, &inlen, ctx);
  if (inlen <= 0) { kk_string_drop(input, ctx); return aw_str_empty(ctx); }
  unsigned char* out = (unsigned char*)malloc((size_t)inlen);
  if (!out) { kk_string_drop(input, ctx); return aw_str_empty(ctx); }
  int n = EVP_DecodeBlock(out, (const unsigned char*)in, (int)inlen);
  if (n < 0) { free(out); kk_string_drop(input, ctx); return aw_str_empty(ctx); }
  /* Strip trailing padding bytes that DecodeBlock leaves in place. */
  if (inlen > 0 && in[inlen - 1] == '=') n--;
  if (inlen > 1 && in[inlen - 2] == '=') n--;
  if (n < 0) n = 0;
  kk_string_t s = aw_str_from_bytes(out, (size_t)n, ctx);
  free(out);
  kk_string_drop(input, ctx);
  return s;
}

/* ---------- RSA sign / verify ---------- */

static EVP_PKEY* aw_priv_from_pem(const char* pem, size_t len) {
  BIO* bio = BIO_new_mem_buf(pem, (int)len);
  if (!bio) return NULL;
  EVP_PKEY* k = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return k;
}

static EVP_PKEY* aw_pub_from_pem(const char* pem, size_t len) {
  BIO* bio = BIO_new_mem_buf(pem, (int)len);
  if (!bio) return NULL;
  EVP_PKEY* k = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
  if (!k) {
    /* Try the RSAPublicKey-style PEM. */
    BIO_reset(bio);
    RSA* rsa = PEM_read_bio_RSA_PUBKEY(bio, NULL, NULL, NULL);
    if (rsa) {
      k = EVP_PKEY_new();
      EVP_PKEY_assign_RSA(k, rsa);
    }
  }
  BIO_free(bio);
  return k;
}

kk_string_t kk_aw_rsa_sign(kk_string_t priv_pem, kk_string_t msg, kk_context_t* ctx) {
  kk_ssize_t pemlen = 0, msglen = 0;
  const char* pem = aw_cstr(priv_pem, &pemlen, ctx);
  const char* m   = aw_cstr(msg,      &msglen, ctx);
  kk_string_t result = aw_str_empty(ctx);

  EVP_PKEY* pk = aw_priv_from_pem(pem, (size_t)pemlen);
  if (pk) {
    EVP_MD_CTX* mdctx = EVP_MD_CTX_new();
    if (mdctx && EVP_DigestSignInit(mdctx, NULL, EVP_sha256(), NULL, pk) == 1 &&
        EVP_DigestSignUpdate(mdctx, m, (size_t)msglen) == 1) {
      size_t sig_len = 0;
      if (EVP_DigestSignFinal(mdctx, NULL, &sig_len) == 1) {
        unsigned char* sig = (unsigned char*)malloc(sig_len);
        if (sig && EVP_DigestSignFinal(mdctx, sig, &sig_len) == 1) {
          result = aw_str_from_bytes(sig, sig_len, ctx);
        }
        free(sig);
      }
    }
    EVP_MD_CTX_free(mdctx);
    EVP_PKEY_free(pk);
  }
  kk_string_drop(priv_pem, ctx);
  kk_string_drop(msg, ctx);
  return result;
}

kk_integer_t kk_aw_rsa_verify(kk_string_t pub_pem, kk_string_t msg,
                              kk_string_t sig, kk_context_t* ctx) {
  kk_ssize_t pemlen = 0, msglen = 0, siglen = 0;
  const char* pem = aw_cstr(pub_pem, &pemlen, ctx);
  const char* m   = aw_cstr(msg,     &msglen, ctx);
  const char* s   = aw_cstr(sig,     &siglen, ctx);
  int ok = 0;

  EVP_PKEY* pk = aw_pub_from_pem(pem, (size_t)pemlen);
  if (pk) {
    EVP_MD_CTX* mdctx = EVP_MD_CTX_new();
    if (mdctx && EVP_DigestVerifyInit(mdctx, NULL, EVP_sha256(), NULL, pk) == 1 &&
        EVP_DigestVerifyUpdate(mdctx, m, (size_t)msglen) == 1 &&
        EVP_DigestVerifyFinal(mdctx, (const unsigned char*)s, (size_t)siglen) == 1) {
      ok = 1;
    }
    EVP_MD_CTX_free(mdctx);
    EVP_PKEY_free(pk);
  }
  kk_string_drop(pub_pem, ctx);
  kk_string_drop(msg, ctx);
  kk_string_drop(sig, ctx);
  return kk_integer_from_int(ok, ctx);
}

/* ---------- RSA keygen ---------- */

kk_string_t kk_aw_rsa_keygen(kk_context_t* ctx) {
  kk_string_t result = aw_str_empty(ctx);
  EVP_PKEY_CTX* pctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
  if (!pctx) return result;
  EVP_PKEY* pk = NULL;
  if (EVP_PKEY_keygen_init(pctx) == 1 &&
      EVP_PKEY_CTX_set_rsa_keygen_bits(pctx, 2048) == 1 &&
      EVP_PKEY_keygen(pctx, &pk) == 1 && pk) {
    BIO* privbio = BIO_new(BIO_s_mem());
    BIO* pubbio  = BIO_new(BIO_s_mem());
    if (privbio && pubbio &&
        PEM_write_bio_PrivateKey(privbio, pk, NULL, NULL, 0, NULL, NULL) == 1 &&
        PEM_write_bio_PUBKEY(pubbio, pk) == 1) {
      char* priv_buf = NULL; long priv_len = BIO_get_mem_data(privbio, &priv_buf);
      char* pub_buf  = NULL; long pub_len  = BIO_get_mem_data(pubbio,  &pub_buf);
      size_t total = (size_t)priv_len + 1 + (size_t)pub_len + 1;
      char* combined = (char*)malloc(total);
      if (combined) {
        memcpy(combined, priv_buf, (size_t)priv_len);
        combined[priv_len] = 0x1F;        /* unit separator */
        memcpy(combined + priv_len + 1, pub_buf, (size_t)pub_len);
        combined[priv_len + 1 + pub_len] = 0;
        result = aw_str_from_bytes((uint8_t*)combined,
                                    (size_t)(priv_len + 1 + pub_len), ctx);
        free(combined);
      }
    }
    BIO_free(privbio);
    BIO_free(pubbio);
    EVP_PKEY_free(pk);
  }
  EVP_PKEY_CTX_free(pctx);
  return result;
}

/* ---------- Argon2id (with PBKDF2 fallback) ---------- */

#ifndef ANNEXWYRM_NO_ARGON2
#  if __has_include(<argon2.h>)
#    include <argon2.h>
#    define ANNEXWYRM_HAVE_ARGON2 1
#  endif
#endif

kk_string_t kk_aw_argon2id_hash(kk_string_t password, kk_context_t* ctx) {
  kk_ssize_t pwlen = 0;
  const char* pw = aw_cstr(password, &pwlen, ctx);
  kk_string_t result = aw_str_empty(ctx);

#ifdef ANNEXWYRM_HAVE_ARGON2
  uint8_t salt[16];
  RAND_bytes(salt, sizeof(salt));
  char encoded[256];
  /* m_cost = 64MiB, t_cost = 3, parallelism = 4 — defaults for a small daemon. */
  int rc = argon2id_hash_encoded(3, 1 << 16, 4,
                                  pw, (size_t)pwlen,
                                  salt, sizeof(salt),
                                  32,
                                  encoded, sizeof(encoded));
  if (rc == ARGON2_OK) {
    result = aw_str_from_cstr(encoded, ctx);
  }
#else
  /* Fallback: $pbkdf2-sha256$i=120000$<salt>$<hash> */
  uint8_t salt[16], out[32];
  RAND_bytes(salt, sizeof(salt));
  if (PKCS5_PBKDF2_HMAC(pw, (int)pwlen, salt, sizeof(salt), 120000,
                        EVP_sha256(), sizeof(out), out) == 1) {
    char b64salt[32], b64out[64];
    EVP_EncodeBlock((unsigned char*)b64salt, salt, sizeof(salt));
    EVP_EncodeBlock((unsigned char*)b64out,  out, sizeof(out));
    char encoded[256];
    snprintf(encoded, sizeof(encoded), "$pbkdf2-sha256$i=120000$%s$%s",
             b64salt, b64out);
    result = aw_str_from_cstr(encoded, ctx);
  }
#endif

  kk_string_drop(password, ctx);
  return result;
}

kk_integer_t kk_aw_argon2id_verify(kk_string_t phc, kk_string_t password,
                                   kk_context_t* ctx) {
  kk_ssize_t phclen = 0, pwlen = 0;
  const char* phc_s = aw_cstr(phc, &phclen, ctx);
  const char* pw    = aw_cstr(password, &pwlen, ctx);
  int ok = 0;

#ifdef ANNEXWYRM_HAVE_ARGON2
  if (strncmp(phc_s, "$argon2", 7) == 0) {
    ok = (argon2id_verify(phc_s, pw, (size_t)pwlen) == ARGON2_OK);
  } else
#endif
  {
    /* PBKDF2 fallback path */
    if (strncmp(phc_s, "$pbkdf2-sha256$", 15) == 0) {
      /* parse $pbkdf2-sha256$i=<n>$<salt>$<hash> */
      int iters = 0;
      char b64salt[64], b64hash[128];
      if (sscanf(phc_s, "$pbkdf2-sha256$i=%d$%63[^$]$%127s",
                 &iters, b64salt, b64hash) == 3) {
        uint8_t salt[64], hash[64], chk[64];
        int saltlen = EVP_DecodeBlock(salt, (const unsigned char*)b64salt,
                                       (int)strlen(b64salt));
        int hashlen = EVP_DecodeBlock(hash, (const unsigned char*)b64hash,
                                       (int)strlen(b64hash));
        if (saltlen > 0 && hashlen > 0 &&
            (size_t)hashlen <= sizeof(chk) &&
            PKCS5_PBKDF2_HMAC(pw, (int)pwlen, salt, saltlen,
                              iters, EVP_sha256(), hashlen, chk) == 1) {
          ok = (memcmp(chk, hash, (size_t)hashlen) == 0);
        }
      }
    }
  }

  kk_string_drop(phc, ctx);
  kk_string_drop(password, ctx);
  return kk_integer_from_int(ok, ctx);
}
