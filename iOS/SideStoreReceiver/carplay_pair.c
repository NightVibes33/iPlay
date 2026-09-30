/*
 * carplay_pair.c — Apple AirPlay SRP pair-setup & pair-verify
 *
 * Implements Apple's modified SRP-6a protocol for HomeKit pairing,
 * as used by AirPlay 2 / wireless CarPlay receivers.
 *
 * Pair-setup flow (M1→M6):
 *   M1: Client → Server: State=1, Method=0 (PairSetup)
 *   M2: Server → Client: State=2, Salt(16), PublicKey(SRP-B, 384)
 *   M3: Client → Server: State=3, PublicKey(SRP-A, 384), Proof(64)
 *   M4: Server → Client: State=4, Proof(64)
 *   M5: Client → Server: State=5, EncryptedData(epk+tag, 48)
 *   M6: Server → Client: State=6, EncryptedData(epk+tag, 48)
 *
 * SRP parameters (Apple variant, iOS 18+ CarPlay):
 *   Group: 3072-bit (RFC 5054 / RFC 3526)
 *   Hash: SHA-512 with a single 64-byte session key
 *   Salt: 16 bytes
 *   Session key: 64 bytes = SHA-512(S) (single hash for SHA-512 variant)
 *   Username: "Pair-Setup"
 *   RFC 5054 compatible: yes
 *
 * Pair-verify flow (M1→M4):
 *   M1: Client → Server: State=1, PublicKey(X25519, 32)
 *   M2: Server → Client: State=2, PublicKey(X25519, 32), EncryptedData(sig, 64)
 *   M3: Client → Server: State=3, EncryptedData(sig, 64)
 *   M4: Server → Client: State=4 (success)
 *
 * Adapted from UxPlay (LGPL/MIT) srp.c/pairing.c/crypto.c
 * SRP-6a core from csrp by Tom Cocagne (MIT license)
 *
 * Crypto is embedded so the package has no external OpenSSL dependency:
 *   - Monocypher 4.0.2: SHA-512/HKDF, ChaCha20-Poly1305, X25519, Ed25519
 *   - LibTomMath 1.3.0: SRP 3072-bit modular arithmetic
 *   - Security.framework: system CSPRNG
 */

#include "carplay_pair.h"

#include "vendor/monocypher/monocypher.h"
#include "vendor/monocypher/monocypher-ed25519.h"
#include "vendor/libtommath/tommath.h"
#include <Security/SecRandom.h>

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>

/* carplay_services owns the process-wide, monotonic line logger. */
extern int showcase_service_log_printf(const char *format, ...);
#define printf showcase_service_log_printf

#define SHA512_DIGEST_LENGTH 64

/* Small OpenSSL-BN compatibility layer backed by LibTomMath. Keeping the
 * existing SRP code unchanged makes the replacement easy to audit against
 * the already-working protocol implementation. */
typedef mp_int BIGNUM;
typedef struct { int unused; } BN_CTX;

static BIGNUM *BN_new(void) {
    BIGNUM *value = malloc(sizeof(*value));
    if (!value || mp_init(value) != MP_OKAY) {
        free(value);
        return NULL;
    }
    return value;
}

static void BN_free(BIGNUM *value) {
    if (!value) return;
    mp_clear(value);
    free(value);
}

static BN_CTX *BN_CTX_new(void) {
    return calloc(1, sizeof(BN_CTX));
}

static void BN_CTX_free(BN_CTX *ctx) {
    free(ctx);
}

static int BN_hex2bn(BIGNUM **value, const char *hex) {
    if (!value || !hex) return 0;
    if (!*value) *value = BN_new();
    if (!*value || mp_read_radix(*value, hex, 16) != MP_OKAY) return 0;
    return (int)strlen(hex);
}

static int BN_num_bytes(const BIGNUM *value) {
    return value ? (int)mp_ubin_size(value) : 0;
}

static int BN_bn2bin(const BIGNUM *value, unsigned char *out) {
    if (!value || !out) return 0;
    size_t length = mp_ubin_size(value);
    return mp_to_ubin(value, out, length, NULL) == MP_OKAY
        ? (int)length : 0;
}

static BIGNUM *BN_bin2bn(const unsigned char *bytes, int length,
                         BIGNUM *value) {
    if (!bytes || length < 0) return NULL;
    if (!value) value = BN_new();
    if (!value || mp_from_ubin(value, bytes, (size_t)length) != MP_OKAY) {
        BN_free(value);
        return NULL;
    }
    return value;
}

static int BN_rand(BIGNUM *value, int bits, int top, int bottom) {
    (void)top;
    (void)bottom;
    if (!value || bits <= 0) return 0;
    size_t length = (size_t)((bits + 7) / 8);
    unsigned char *bytes = malloc(length);
    if (!bytes) return 0;
    int ok = SecRandomCopyBytes(kSecRandomDefault, length, bytes) == errSecSuccess;
    if (ok && (bits & 7)) bytes[0] &= (uint8_t)((1U << (bits & 7)) - 1U);
    if (ok) ok = mp_from_ubin(value, bytes, length) == MP_OKAY;
    crypto_wipe(bytes, length);
    free(bytes);
    return ok;
}

static int BN_mod_exp(BIGNUM *r, const BIGNUM *a, const BIGNUM *p,
                      const BIGNUM *m, BN_CTX *ctx) {
    (void)ctx;
    return mp_exptmod(a, p, m, r) == MP_OKAY;
}

static int BN_mod_mul(BIGNUM *r, const BIGNUM *a, const BIGNUM *b,
                      const BIGNUM *m, BN_CTX *ctx) {
    (void)ctx;
    return mp_mulmod(a, b, m, r) == MP_OKAY;
}

static int BN_mod_add(BIGNUM *r, const BIGNUM *a, const BIGNUM *b,
                      const BIGNUM *m, BN_CTX *ctx) {
    (void)ctx;
    return mp_addmod(a, b, m, r) == MP_OKAY;
}

static int BN_mod(BIGNUM *r, const BIGNUM *a, const BIGNUM *m,
                  BN_CTX *ctx) {
    (void)ctx;
    return mp_mod(a, m, r) == MP_OKAY;
}

static int BN_mul(BIGNUM *r, const BIGNUM *a, const BIGNUM *b,
                  BN_CTX *ctx) {
    (void)ctx;
    return mp_mul(a, b, r) == MP_OKAY;
}

static int BN_is_zero(const BIGNUM *value) {
    return mp_iszero(value) == MP_YES;
}

/* ═══════════════════════════════════════════════════════════════
 * 1. Configuration
 * ═══════════════════════════════════════════════════════════════ */

#define SRP_DEFAULT_PIN  "3939"
#define SRP_USERNAME     "Pair-Setup"
#define SRP_SALT_BYTES   16
#define SRP_HASH_LEN     SHA512_DIGEST_LENGTH /* 64 (SHA-512) */
#define SRP_SKEY_LEN     SRP_HASH_LEN         /* 64 (single SHA-512 for 3072-bit) */
#define GCM_TAG_LEN      16
#define ED25519_KEY_LEN  32
#define MAX_PAIRED_PEERS 8
#define MAX_PEER_IDENTIFIER_LEN 128

/* TLV8 type constants */
#define TLV_METHOD          0x00
#define TLV_IDENTIFIER      0x01
#define TLV_SALT            0x02
#define TLV_PUBLIC_KEY      0x03
#define TLV_PROOF           0x04
#define TLV_ENCRYPTED_DATA  0x05
#define TLV_STATE           0x06
#define TLV_ERROR           0x07
#define TLV_SIGNATURE       0x0A

/* ═══════════════════════════════════════════════════════════════
 * 2. SRP-6a Implementation (adapted from UxPlay/csrp)
 *    Apple variant: 64-byte session key, 16-byte salt,
 *    SHA-512 hash, RFC 5054 compatible k computation
 * ═══════════════════════════════════════════════════════════════ */

/* RFC 5054 / RFC 3526 3072-bit group (g=5) */
static const char *N_3072_hex =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6"
    "3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411"
    "7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08"
    "CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
    "DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D"
    "04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
    "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273"
    "3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31"
    "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

typedef struct { BIGNUM *N; BIGNUM *g; } ng_t;

static ng_t *ng_new(void) {
    ng_t *ng = calloc(1, sizeof(ng_t));
    if (!ng) return NULL;
    ng->N = BN_new();
    ng->g = BN_new();
    if (!ng->N || !ng->g) { free(ng); return NULL; }
    BN_hex2bn(&ng->N, N_3072_hex);
    BN_hex2bn(&ng->g, "5");
    return ng;
}

static void ng_free(ng_t *ng) {
    if (ng) {
        BN_free(ng->N);
        BN_free(ng->g);
        free(ng);
    }
}

/* --- Hash utilities (SHA-512 via embedded Monocypher) --- */

typedef struct { crypto_sha512_ctx ctx; } hctx_t;

static hctx_t *hctx_new(void) {
    return calloc(1, sizeof(hctx_t));
}

static void hctx_free(hctx_t *h) {
    if (h) {
        crypto_wipe(h, sizeof(*h));
        free(h);
    }
}

static int hctx_init(hctx_t *h) {
    crypto_sha512_init(&h->ctx);
    return 1;
}

static int hctx_update(hctx_t *h, const void *data, size_t len) {
    crypto_sha512_update(&h->ctx, data, len);
    return 1;
}

static int hctx_final(hctx_t *h, unsigned char *md, unsigned int *len) {
    crypto_sha512_final(&h->ctx, md);
    if (len) *len = SHA512_DIGEST_LENGTH;
    return 1;
}

/* Quick SHA-512 hash */
static void hash_bytes(const unsigned char *d, size_t n, unsigned char *md) {
    crypto_sha512(md, d, n);
}

/* --- BIGNUM hash helpers --- */

/* H(n1 || n2) with RFC 5054 zero-padding to len(N) */
static BIGNUM *H_nn_pad(const BIGNUM *N, const BIGNUM *n1, const BIGNUM *n2) {
    unsigned char buf[SRP_HASH_LEN];
    int len_N = BN_num_bytes(N);
    int nbytes = len_N * 2;
    unsigned char *bin = calloc(1, nbytes);
    if (!bin) return NULL;

    int l1 = BN_num_bytes(n1);
    int l2 = BN_num_bytes(n2);
    if (l1 > len_N || l2 > len_N) { free(bin); return NULL; }

    BN_bn2bin(n1, bin + (len_N - l1));
    BN_bn2bin(n2, bin + (len_N + len_N - l2));
    hash_bytes(bin, nbytes, buf);
    free(bin);
    return BN_bin2bn(buf, SRP_HASH_LEN, NULL);
}

/* H(n || bytes) */
static BIGNUM *H_ns(const BIGNUM *n, const unsigned char *bytes, int len_bytes) {
    unsigned char buf[SRP_HASH_LEN];
    int len_n = BN_num_bytes(n);
    int nbytes = len_n + len_bytes;
    unsigned char *bin = malloc(nbytes);
    if (!bin) return NULL;
    BN_bn2bin(n, bin);
    memcpy(bin + len_n, bytes, len_bytes);
    hash_bytes(bin, nbytes, buf);
    free(bin);
    return BN_bin2bn(buf, SRP_HASH_LEN, NULL);
}

/* x = H(salt || H(username:password)) */
static BIGNUM *calculate_x(const BIGNUM *salt, const char *username,
                            const unsigned char *password, int pw_len) {
    unsigned char ucp_hash[SRP_HASH_LEN];
    unsigned int ucp_hash_len;
    hctx_t *h = hctx_new();
    if (!h) return NULL;

    hctx_init(h);
    hctx_update(h, username, strlen(username));
    hctx_update(h, ":", 1);
    hctx_update(h, password, pw_len);
    hctx_final(h, ucp_hash, &ucp_hash_len);
    hctx_free(h);

    return H_ns(salt, ucp_hash, SRP_HASH_LEN);
}

/* Hash update with BIGNUM data */
static void hash_update_bn(hctx_t *h, const BIGNUM *n) {
    int len = BN_num_bytes(n);
    unsigned char *bin = malloc(len);
    if (!bin) return;
    BN_bn2bin(n, bin);
    hctx_update(h, bin, len);
    free(bin);
}

/* H(n) → dest (SRP_HASH_LEN bytes) */
static void hash_bn(const BIGNUM *n, unsigned char *dest) {
    int len = BN_num_bytes(n);
    unsigned char *bin = malloc(len);
    if (!bin) return;
    BN_bn2bin(n, bin);
    hash_bytes(bin, len, dest);
    free(bin);
}

/* Session key: K = SHA-512(S) — single hash for SHA-512 variant.
 * (The double-hash Apple variant is only for SHA-1 where keyLen == 40.) */
static int hash_session_key(const BIGNUM *S, unsigned char *dest) {
    int nbytes = BN_num_bytes(S);
    unsigned char *bin = malloc(nbytes);
    if (!bin) return -1;
    BN_bn2bin(S, bin);

    unsigned int len;
    hctx_t *h = hctx_new();
    if (!h) { free(bin); return -1; }

    hctx_init(h);
    hctx_update(h, bin, nbytes);
    hctx_final(h, dest, &len);
    hctx_free(h);
    free(bin);
    return (int)len;  /* 64 */
}

static int hash_session_key_padded(const BIGNUM *S, int padded_len,
                                   unsigned char *dest) {
    int nbytes = BN_num_bytes(S);
    if (nbytes < 0 || nbytes > padded_len) return -1;
    unsigned char *bin = calloc(1, padded_len);
    if (!bin) return -1;
    BN_bn2bin(S, bin + (padded_len - nbytes));

    unsigned int len;
    hctx_t *h = hctx_new();
    if (!h) { free(bin); return -1; }

    hctx_init(h);
    hctx_update(h, bin, padded_len);
    hctx_final(h, dest, &len);
    hctx_free(h);
    free(bin);
    return (int)len;
}

/* M = H(H(N) xor H(g) || H(I) || s || PAD(A) || PAD(B) || K)
 * A and B are LEFT-PADDED to N_length per SRP_FLAG_LEFT_PAD (Apple SDK).
 * Salt is raw bytes (not BIGNUM-converted). */
static void calculate_M(ng_t *ng, unsigned char *dest, const char *I,
                         const unsigned char *salt_bytes, int salt_len,
                         const BIGNUM *A, const BIGNUM *B,
                         const unsigned char *K) {
    unsigned char H_N[SRP_HASH_LEN] = {0};
    unsigned char H_g[SRP_HASH_LEN] = {0};
    unsigned char H_I[SRP_HASH_LEN] = {0};
    unsigned char H_xor[SRP_HASH_LEN] = {0};
    unsigned int dest_len;
    int len_N = BN_num_bytes(ng->N);

    hash_bn(ng->N, H_N);
    hash_bn(ng->g, H_g);
    hash_bytes((const unsigned char *)I, strlen(I), H_I);

    for (int i = 0; i < SRP_HASH_LEN; i++)
        H_xor[i] = H_N[i] ^ H_g[i];

    /* LEFT-PAD A and B to N_length */
    unsigned char *A_pad = calloc(1, len_N);
    unsigned char *B_pad = calloc(1, len_N);
    int A_bytes = BN_num_bytes(A);
    int B_bytes = BN_num_bytes(B);
    BN_bn2bin(A, A_pad + (len_N - A_bytes));
    BN_bn2bin(B, B_pad + (len_N - B_bytes));

    hctx_t *h = hctx_new();
    hctx_init(h);
    hctx_update(h, H_xor, SRP_HASH_LEN);
    hctx_update(h, H_I, SRP_HASH_LEN);
    hctx_update(h, salt_bytes, salt_len);  /* raw salt bytes */
    hctx_update(h, A_pad, len_N);          /* LEFT-PAD A */
    hctx_update(h, B_pad, len_N);          /* LEFT-PAD B */
    hctx_update(h, K, SRP_SKEY_LEN);
    hctx_final(h, dest, &dest_len);
    hctx_free(h);
    free(A_pad);
    free(B_pad);
}

/* H_AMK = H(PAD(A) || M || K) — A is LEFT-PADDED to N_length */
static void calculate_H_AMK(unsigned char *dest, const BIGNUM *A,
                              const unsigned char *M, const unsigned char *K,
                              int len_N) {
    unsigned int dest_len;
    unsigned char *A_pad = calloc(1, len_N);
    int A_bytes = BN_num_bytes(A);
    BN_bn2bin(A, A_pad + (len_N - A_bytes));

    hctx_t *h = hctx_new();
    hctx_init(h);
    hctx_update(h, A_pad, len_N);
    hctx_update(h, M, SRP_HASH_LEN);
    hctx_update(h, K, SRP_SKEY_LEN);
    hctx_final(h, dest, &dest_len);
    hctx_free(h);
    free(A_pad);
}

/* --- SRP Verifier --- */

typedef struct {
    ng_t *ng;
    char *username;
    unsigned char *bytes_B;
    int authenticated;
    unsigned char M[SRP_HASH_LEN];
    unsigned char H_AMK[SRP_HASH_LEN];
    unsigned char session_key[SRP_SKEY_LEN];
    unsigned char M_padded[SRP_HASH_LEN];
    unsigned char H_AMK_padded[SRP_HASH_LEN];
    unsigned char session_key_padded[SRP_SKEY_LEN];
    int S_minimal_len;
    int N_len;
    int proof_mode;  /* 1=minimal-S KDF, 2=padded-S KDF */
} srp_verifier_t;

static void srp_init_random(void) {
    /* SecRandomCopyBytes is ready without application-managed seeding. */
}

/* Create salt + verifier from username/password */
static int srp_create_salt_verifier(const char *username,
                                     const unsigned char *password, int pw_len,
                                     unsigned char salt_out[SRP_SALT_BYTES],
                                     unsigned char **verifier_out, int *verifier_len) {
    BIGNUM *s = BN_new(), *v = BN_new(), *x = NULL;
    BN_CTX *ctx = BN_CTX_new();
    ng_t *ng = ng_new();
    int ret = -1;

    if (!s || !v || !ctx || !ng) goto done;
    srp_init_random();

    BN_rand(s, SRP_SALT_BYTES * 8, -1, 0);
    x = calculate_x(s, username, password, pw_len);
    if (!x) goto done;

    BN_mod_exp(v, ng->g, x, ng->N, ctx);

    int slen = BN_num_bytes(s);
    int vlen = BN_num_bytes(v);

    /* Pad salt to exactly SRP_SALT_BYTES */
    memset(salt_out, 0, SRP_SALT_BYTES);
    if (slen <= SRP_SALT_BYTES)
        BN_bn2bin(s, salt_out + (SRP_SALT_BYTES - slen));
    else
        BN_bn2bin(s, salt_out);  /* shouldn't happen */

    *verifier_out = malloc(vlen);
    if (!*verifier_out) goto done;
    BN_bn2bin(v, *verifier_out);
    *verifier_len = vlen;
    ret = 0;

done:
    ng_free(ng);
    BN_free(s); BN_free(v); BN_free(x);
    BN_CTX_free(ctx);
    return ret;
}

/* Create server ephemeral key B from verifier and private key b.
 * B = k*v + g^b (mod N)  with RFC 5054 k computation */
static int srp_create_B(const unsigned char *verifier, int vlen,
                         const unsigned char *b_bytes, int blen,
                         unsigned char **B_out, int *B_len) {
    BIGNUM *v = BN_bin2bn(verifier, vlen, NULL);
    BIGNUM *b = BN_bin2bn(b_bytes, blen, NULL);
    BIGNUM *B = BN_new();
    BIGNUM *k = NULL;
    BIGNUM *tmp1 = BN_new(), *tmp2 = BN_new();
    BN_CTX *ctx = BN_CTX_new();
    ng_t *ng = ng_new();
    int ret = -1;

    *B_out = NULL; *B_len = 0;
    if (!v || !b || !B || !tmp1 || !tmp2 || !ctx || !ng) goto done;

    /* RFC 5054: k = H(N || pad(g)) */
    k = H_nn_pad(ng->N, ng->N, ng->g);
    if (!k) goto done;

    /* B = k*v + g^b (mod N) */
    BN_mod_mul(tmp1, k, v, ng->N, ctx);
    BN_mod_exp(tmp2, ng->g, b, ng->N, ctx);
    BN_mod_add(B, tmp1, tmp2, ng->N, ctx);

    *B_len = BN_num_bytes(B);
    *B_out = malloc(*B_len);
    if (!*B_out) goto done;
    BN_bn2bin(B, *B_out);
    ret = 0;

done:
    ng_free(ng);
    BN_free(v); BN_free(b); BN_free(B);
    if (k) BN_free(k);
    BN_free(tmp1); BN_free(tmp2);
    BN_CTX_free(ctx);
    return ret;
}

/* Create SRP verifier object for M3 proof verification.
 * Returns verifier with computed M and H_AMK, or NULL on failure. */
static srp_verifier_t *srp_verifier_new(const char *username,
                                          const unsigned char *salt, int salt_len,
                                          const unsigned char *verifier, int vlen,
                                          const unsigned char *bytes_A, int A_len,
                                          const unsigned char *bytes_b, int b_len) {
    BIGNUM *s = BN_bin2bn(salt, salt_len, NULL);
    BIGNUM *v = BN_bin2bn(verifier, vlen, NULL);
    BIGNUM *A = BN_bin2bn(bytes_A, A_len, NULL);
    BIGNUM *B = BN_new(), *S = BN_new();
    BIGNUM *b = BN_bin2bn(bytes_b, b_len, NULL);
    BIGNUM *u = NULL, *k = NULL;
    BIGNUM *tmp1 = BN_new(), *tmp2 = BN_new();
    BN_CTX *ctx = BN_CTX_new();
    ng_t *ng = ng_new();
    srp_verifier_t *ver = NULL;

    if (!s || !v || !A || !B || !S || !b || !tmp1 || !tmp2 || !ctx || !ng)
        goto done;

    /* SRP-6a safety check: A mod N != 0 */
    BN_mod(tmp1, A, ng->N, ctx);
    if (BN_is_zero(tmp1)) goto done;

    /* k = H(N || pad(g)) */
    k = H_nn_pad(ng->N, ng->N, ng->g);
    if (!k) goto done;

    /* B = k*v + g^b (mod N) */
    BN_mod_mul(tmp1, k, v, ng->N, ctx);
    BN_mod_exp(tmp2, ng->g, b, ng->N, ctx);
    BN_mod_add(B, tmp1, tmp2, ng->N, ctx);

    /* u = H(A || B) (RFC 5054 padded) */
    u = H_nn_pad(ng->N, A, B);
    if (!u) goto done;

    /* S = (A * v^u) ^ b (mod N) */
    BN_mod_exp(tmp1, v, u, ng->N, ctx);
    BN_mul(tmp2, A, tmp1, ctx);
    BN_mod_exp(S, tmp2, b, ng->N, ctx);

    /* Allocate verifier */
    ver = calloc(1, sizeof(srp_verifier_t));
    if (!ver) goto done;

    ver->ng = ng_new();
    int ulen = strlen(username) + 1;
    ver->username = malloc(ulen);
    if (!ver->username) { free(ver); ver = NULL; goto done; }
    memcpy(ver->username, username, ulen);
    ver->authenticated = 0;

    int len_N = BN_num_bytes(ver->ng->N);
    ver->N_len = len_N;
    ver->S_minimal_len = BN_num_bytes(S);

    /* Session key compatibility:
     * - minimal-S KDF is the behavior existing working devices used.
     * - padded-S KDF covers clients that expect SHA512(PAD(S, len(N))).
     * The verifier chooses the matching mode only after comparing M3. */
    if (hash_session_key(S, ver->session_key) != SRP_SKEY_LEN ||
        hash_session_key_padded(S, len_N, ver->session_key_padded) != SRP_SKEY_LEN) {
        ng_free(ver->ng);
        free(ver->username);
        free(ver);
        ver = NULL;
        goto done;
    }

    /* Compute expected client proof M and server proof H_AMK.
     * Pass raw salt bytes (not BIGNUM) to avoid leading-zero stripping. */
    calculate_M(ver->ng, ver->M, username, salt, salt_len, A, B, ver->session_key);
    calculate_H_AMK(ver->H_AMK, A, ver->M, ver->session_key, len_N);
    calculate_M(ver->ng, ver->M_padded, username, salt, salt_len, A, B,
                ver->session_key_padded);
    calculate_H_AMK(ver->H_AMK_padded, A, ver->M_padded,
                    ver->session_key_padded, len_N);

    /* Store B for reference */
    ver->bytes_B = malloc(BN_num_bytes(B));
    if (ver->bytes_B)
        BN_bn2bin(B, ver->bytes_B);

done:
    BN_free(s); BN_free(v); BN_free(A);
    if (u) BN_free(u);
    if (k) BN_free(k);
    BN_free(B); BN_free(S); BN_free(b);
    BN_free(tmp1); BN_free(tmp2);
    BN_CTX_free(ctx);
    /* ng is owned by ver if created, else freed */
    if (!ver) ng_free(ng);
    return ver;
}

static int srp_verifier_verify(srp_verifier_t *ver,
                                const unsigned char *client_M,
                                const unsigned char **server_M2) {
    printf("[PAIR] SRP S minimal len=%d, N len=%d\n",
           ver->S_minimal_len, ver->N_len);
    if (memcmp(ver->M, client_M, SRP_HASH_LEN) == 0) {
        ver->authenticated = 1;
        ver->proof_mode = 1;
        *server_M2 = ver->H_AMK;
        printf("[PAIR] SRP proof matched using minimal-S KDF\n");
        return 0;
    }
    if (memcmp(ver->M_padded, client_M, SRP_HASH_LEN) == 0) {
        ver->authenticated = 1;
        ver->proof_mode = 2;
        memcpy(ver->session_key, ver->session_key_padded, SRP_SKEY_LEN);
        memcpy(ver->M, ver->M_padded, SRP_HASH_LEN);
        memcpy(ver->H_AMK, ver->H_AMK_padded, SRP_HASH_LEN);
        *server_M2 = ver->H_AMK;
        printf("[PAIR] SRP proof matched using padded-S KDF\n");
        return 0;
    }
    *server_M2 = NULL;
    printf("[PAIR] SRP proof mismatch using both minimal and padded KDF\n");
    return -1;
}

static void srp_verifier_delete(srp_verifier_t *ver) {
    if (ver) {
        ng_free(ver->ng);
        free(ver->username);
        free(ver->bytes_B);
        memset(ver, 0, sizeof(*ver));
        free(ver);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * 3. TLV8 Utilities
 * ═══════════════════════════════════════════════════════════════ */

#define MAX_TLV_ITEMS 16

typedef struct {
    uint8_t type;
    uint8_t *data;   /* heap-allocated */
    size_t  len;
} tlv_item_t;

typedef struct {
    tlv_item_t items[MAX_TLV_ITEMS];
    int count;
} tlv_t;

/* Parse TLV8 with fragment reassembly.
 * Consecutive entries with same type are concatenated. */
static tlv_t *tlv_parse(const uint8_t *buf, size_t len) {
    tlv_t *t = calloc(1, sizeof(tlv_t));
    if (!t) return NULL;

    size_t i = 0;
    while (i + 2 <= len) {
        uint8_t type = buf[i];
        uint8_t tlen = buf[i + 1];
        if (i + 2 + tlen > len) break;

        /* Check if this is a continuation of the previous item */
        if (t->count > 0 && t->items[t->count - 1].type == type) {
            tlv_item_t *prev = &t->items[t->count - 1];
            uint8_t *newdata = realloc(prev->data, prev->len + tlen);
            if (!newdata) break;
            memcpy(newdata + prev->len, buf + i + 2, tlen);
            prev->data = newdata;
            prev->len += tlen;
        } else {
            if (t->count >= MAX_TLV_ITEMS) break;
            tlv_item_t *item = &t->items[t->count];
            item->type = type;
            item->len = tlen;
            item->data = malloc(tlen > 0 ? tlen : 1);
            if (!item->data) break;
            if (tlen > 0) memcpy(item->data, buf + i + 2, tlen);
            t->count++;
        }
        i += 2 + tlen;
    }
    return t;
}

static const tlv_item_t *tlv_find(const tlv_t *t, uint8_t type) {
    for (int i = 0; i < t->count; i++)
        if (t->items[i].type == type) return &t->items[i];
    return NULL;
}

static void tlv_free(tlv_t *t) {
    if (t) {
        for (int i = 0; i < t->count; i++)
            free(t->items[i].data);
        free(t);
    }
}

/* Build TLV8 output buffer with automatic fragmentation.
 * items: array of {type, data, len} to encode.
 * Returns malloc'd buffer, sets *out_len. Caller must free. */
static uint8_t *tlv_build(const tlv_item_t *items, int count, size_t *out_len) {
    /* Calculate total output size */
    size_t total = 0;
    for (int i = 0; i < count; i++) {
        size_t rem = items[i].len;
        if (rem == 0) {
            total += 2;  /* type + len=0 */
        } else {
            while (rem > 0) {
                size_t chunk = rem > 255 ? 255 : rem;
                total += 2 + chunk;
                rem -= chunk;
            }
        }
    }

    uint8_t *buf = malloc(total);
    if (!buf) { *out_len = 0; return NULL; }

    size_t pos = 0;
    for (int i = 0; i < count; i++) {
        size_t rem = items[i].len;
        size_t off = 0;

        if (rem == 0) {
            buf[pos++] = items[i].type;
            buf[pos++] = 0;
        } else {
            while (rem > 0) {
                size_t chunk = rem > 255 ? 255 : rem;
                buf[pos++] = items[i].type;
                buf[pos++] = (uint8_t)chunk;
                memcpy(buf + pos, items[i].data + off, chunk);
                pos += chunk;
                off += chunk;
                rem -= chunk;
            }
        }
    }

    *out_len = pos;
    return buf;
}

/* ═══════════════════════════════════════════════════════════════
 * 4. HKDF-SHA512 + ChaCha20-Poly1305 (for pair-setup M5/M6)
 *    Apple HAP uses HKDF for key derivation and ChaCha20-Poly1305
 *    for M5/M6 encryption (not AES-GCM).
 * ═══════════════════════════════════════════════════════════════ */

/* HKDF-SHA512 (RFC 5869) — Extract + Expand.
 * For okm_len <= 64, only one HMAC iteration needed. */
static int hkdf_sha512(const unsigned char *ikm, int ikm_len,
                        const unsigned char *salt, int salt_len,
                        const unsigned char *info, int info_len,
                        unsigned char *okm, int okm_len) {
    crypto_sha512_hkdf(okm, (size_t)okm_len,
                       ikm, (size_t)ikm_len,
                       salt, (size_t)salt_len,
                       info, (size_t)info_len);
    return 0;
}

/* Derive 32-byte encryption key for M5/M6:
 *   key = HKDF-SHA512(IKM=session_key,
 *                      salt="Pair-Setup-Encrypt-Salt",
 *                      info="Pair-Setup-Encrypt-Info")[:32] */
static void derive_pair_setup_encrypt_key(const unsigned char *session_key,
                                            int skey_len,
                                            unsigned char key[32]) {
    hkdf_sha512(session_key, skey_len,
                (const unsigned char *)"Pair-Setup-Encrypt-Salt", 23,
                (const unsigned char *)"Pair-Setup-Encrypt-Info", 23,
                key, 32);
}

/* ChaCha20-Poly1305 decrypt.
 * nonce8: 8-byte nonce ("PS-Msg05" etc), padded to 12 with 4 leading zeros. */
static int chacha_decrypt(const unsigned char key[32],
                           const unsigned char *nonce8,
                           const unsigned char *ct, int ct_len,
                           unsigned char *pt,
                           const unsigned char *tag) {
    unsigned char nonce12[12] = {0};
    memcpy(nonce12 + 4, nonce8, 8);

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, nonce12);
    int result = crypto_aead_read(&ctx, pt, tag, NULL, 0,
                                  ct, (size_t)ct_len);
    crypto_wipe(&ctx, sizeof(ctx));
    return result == 0 ? ct_len : -1;
}

/* ChaCha20-Poly1305 encrypt. */
static int chacha_encrypt(const unsigned char key[32],
                           const unsigned char *nonce8,
                           const unsigned char *pt, int pt_len,
                           unsigned char *ct,
                           unsigned char *tag) {
    unsigned char nonce12[12] = {0};
    memcpy(nonce12 + 4, nonce8, 8);

    crypto_aead_ctx ctx;
    crypto_aead_init_ietf(&ctx, key, nonce12);
    crypto_aead_write(&ctx, ct, tag, NULL, 0, pt, (size_t)pt_len);
    crypto_wipe(&ctx, sizeof(ctx));
    return pt_len;
}

/* ═══════════════════════════════════════════════════════════════
 * 6. Pair Context
 * ═══════════════════════════════════════════════════════════════ */

struct pair_ctx_s {
    /* Our identity */
    uint8_t our_sk[32];   /* Ed25519 secret key seed */
    uint8_t our_pk[32];   /* Ed25519 public key */
    char    pin[16];      /* SRP password */

    /* SRP state (persists across M1→M5) */
    uint8_t srp_salt[SRP_SALT_BYTES];
    uint8_t srp_b[32];            /* server private ephemeral */
    uint8_t *srp_verifier;
    int     srp_verifier_len;
    uint8_t srp_session_key[SRP_SKEY_LEN];
    int     srp_has_session_key;

    /* Client's Ed25519 pk (learned in M5) */
    uint8_t client_pk[32];
    int     client_pk_set;
    struct {
        uint8_t identifier[MAX_PEER_IDENTIFIER_LEN];
        size_t identifier_len;
        uint8_t public_key[ED25519_KEY_LEN];
    } peers[MAX_PAIRED_PEERS];
    size_t peer_count;

    /* State machines */
    int setup_state;   /* 0=idle, 2=M2 sent, 4=M4 sent, 6=done */
    int verify_state;  /* 0=idle, 2=M2 sent, 4=done */

    /* Pair-verify ECDH state (persists M1→M3) */
    uint8_t   verify_ecdh_sk[32];   /* our X25519 secret key */
    uint8_t   verify_shared[32];    /* ECDH shared secret */
    uint8_t   verify_enc_key[32];   /* HKDF-derived ChaCha key for M2/M3 */
    uint8_t   verify_our_ecdh_pk[32]; /* our X25519 public key (for M3) */
    uint8_t   client_ecdh_pk[32];   /* client's X25519 public key from M1 */
    int       client_ecdh_pk_set;
};

static int find_peer_index(const pair_ctx_t *ctx, const uint8_t *identifier,
                           size_t identifier_len) {
    if (!ctx || !identifier || identifier_len == 0) return -1;
    for (size_t i = 0; i < ctx->peer_count; i++) {
        if (ctx->peers[i].identifier_len == identifier_len &&
            memcmp(ctx->peers[i].identifier, identifier, identifier_len) == 0)
            return (int)i;
    }
    return -1;
}

int pair_ctx_add_peer(pair_ctx_t *ctx, const uint8_t *identifier,
                      size_t identifier_len, const uint8_t public_key[32]) {
    if (!ctx || !identifier || !public_key || identifier_len == 0 ||
        identifier_len > MAX_PEER_IDENTIFIER_LEN)
        return -1;
    int existing = find_peer_index(ctx, identifier, identifier_len);
    size_t index;
    if (existing >= 0) {
        index = (size_t)existing;
    } else if (ctx->peer_count < MAX_PAIRED_PEERS) {
        index = ctx->peer_count++;
    } else {
        /* Keep the registry bounded. The oldest slot is replaced only when
         * somebody intentionally completes a new authenticated pair-setup. */
        memmove(&ctx->peers[0], &ctx->peers[1],
                sizeof(ctx->peers[0]) * (MAX_PAIRED_PEERS - 1));
        index = MAX_PAIRED_PEERS - 1;
    }
    memcpy(ctx->peers[index].identifier, identifier, identifier_len);
    ctx->peers[index].identifier_len = identifier_len;
    memcpy(ctx->peers[index].public_key, public_key, ED25519_KEY_LEN);
    return 0;
}

size_t pair_ctx_peer_count(const pair_ctx_t *ctx) {
    return ctx ? ctx->peer_count : 0;
}

int pair_ctx_get_peer(const pair_ctx_t *ctx, size_t index,
                      uint8_t *identifier, size_t identifier_capacity,
                      size_t *identifier_len, uint8_t public_key[32]) {
    if (!ctx || index >= ctx->peer_count || !identifier_len || !public_key)
        return -1;
    size_t length = ctx->peers[index].identifier_len;
    *identifier_len = length;
    if (!identifier || identifier_capacity < length) return -1;
    memcpy(identifier, ctx->peers[index].identifier, length);
    memcpy(public_key, ctx->peers[index].public_key, ED25519_KEY_LEN);
    return 0;
}

pair_ctx_t *pair_ctx_create(const uint8_t sk[32], const uint8_t pk[32], const char *pin) {
    pair_ctx_t *ctx = calloc(1, sizeof(pair_ctx_t));
    if (!ctx) return NULL;

    memcpy(ctx->our_sk, sk, 32);
    memcpy(ctx->our_pk, pk, 32);
    strncpy(ctx->pin, pin ? pin : SRP_DEFAULT_PIN, sizeof(ctx->pin) - 1);

    printf("[PAIR] Context created (SRP PIN configured)\n");
    return ctx;
}

int pair_derive_control_keys(pair_ctx_t *ctx, uint8_t readKey[32], uint8_t writeKey[32]) {
    if (!ctx || ctx->verify_state != 4) {
        printf("[PAIR] ERROR: pair-verify not complete, cannot derive control keys\n");
        return -1;
    }
    /* "Read"/"Write" naming is from the CONTROLLER (iPhone) perspective:
     * - "Control-Write-Encryption-Key" = key iPhone uses to WRITE → we use to READ (decrypt incoming)
     * - "Control-Read-Encryption-Key"  = key iPhone uses to READ  → we use to WRITE (encrypt outgoing) */
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)"Control-Salt", 12,
                (const unsigned char *)"Control-Write-Encryption-Key", 28,
                readKey, 32);
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)"Control-Salt", 12,
                (const unsigned char *)"Control-Read-Encryption-Key", 27,
                writeKey, 32);

    printf("[PAIR] Control read  key: ");
    for (int i = 0; i < 32; i++) printf("%02x", readKey[i]);
    printf("\n[PAIR] Control write key: ");
    for (int i = 0; i < 32; i++) printf("%02x", writeKey[i]);
    printf("\n");
    return 0;
}

int pair_derive_event_keys(pair_ctx_t *ctx, uint8_t readKey[32], uint8_t writeKey[32]) {
    if (!ctx || ctx->verify_state != 4) {
        printf("[PAIR] ERROR: pair-verify not complete, cannot derive event keys\n");
        return -1;
    }
    /* Event channel naming is from the RECEIVER's perspective (matching reference
     * _ControlStart in AirPlayReceiverSession.c):
     * - "Events-Read-Encryption-Key"  → readKey  (receiver reads/decrypts incoming)
     * - "Events-Write-Encryption-Key" → writeKey (receiver writes/encrypts outgoing)
     * This is NOT swapped like the control channel keys. */
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)"Events-Salt", 11,
                (const unsigned char *)"Events-Read-Encryption-Key", 26,
                readKey, 32);
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)"Events-Salt", 11,
                (const unsigned char *)"Events-Write-Encryption-Key", 27,
                writeKey, 32);

    printf("[PAIR] Event read  key: ");
    for (int i = 0; i < 32; i++) printf("%02x", readKey[i]);
    printf("\n[PAIR] Event write key: ");
    for (int i = 0; i < 32; i++) printf("%02x", writeKey[i]);
    printf("\n");
    return 0;
}

int pair_derive_stream_key(pair_ctx_t *ctx, uint64_t streamConnectionID, uint8_t outKey[32]) {
    if (!ctx || ctx->verify_state != 4) {
        printf("[PAIR] ERROR: pair-verify not complete, cannot derive stream key\n");
        return -1;
    }
    /* Salt = "DataStream-Salt" + decimal streamConnectionID
     * Info = "DataStream-Output-Encryption-Key" (Output from iPhone = what we receive)
     * Reference: _GetStreamSecurityKeys in AirPlayReceiverSession.c */
    char saltBuf[64];
    int saltLen = snprintf(saltBuf, sizeof(saltBuf), "DataStream-Salt%llu",
                           (unsigned long long)streamConnectionID);
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)saltBuf, saltLen,
                (const unsigned char *)"DataStream-Output-Encryption-Key", 32,
                outKey, 32);
    printf("[PAIR] Stream key (connID=%llu): ", (unsigned long long)streamConnectionID);
    for (int i = 0; i < 32; i++) printf("%02x", outKey[i]);
    printf("\n");
    return 0;
}

void pair_ctx_destroy(pair_ctx_t *ctx) {
    if (ctx) {
        free(ctx->srp_verifier);
        crypto_wipe(ctx, sizeof(*ctx));
        free(ctx);
    }
}

/* ═══════════════════════════════════════════════════════════════
 * 7. Pair-Setup Handler (M1→M6)
 * ═══════════════════════════════════════════════════════════════ */

/* Build error response TLV */
static uint8_t *make_error_response(uint8_t state, uint8_t error_code, size_t *out_len) {
    tlv_item_t items[2] = {
        { TLV_STATE, &state, 1 },
        { TLV_ERROR, &error_code, 1 }
    };
    return tlv_build(items, 2, out_len);
}

/* M1 → M2: Generate SRP salt + server public key */
static uint8_t *handle_setup_m1(pair_ctx_t *ctx, const tlv_t *in, size_t *out_len) {
    printf("[PAIR] pair-setup M1 received (State=1, Method=PairSetup)\n");
    printf("[PAIR] *** PIN: %s *** (enter this if iPhone prompts)\n", ctx->pin);

    /* Reset SRP state for new pairing attempt */
    free(ctx->srp_verifier);
    ctx->srp_verifier = NULL;
    ctx->srp_has_session_key = 0;
    ctx->client_pk_set = 0;

    /* Generate SRP salt + verifier from PIN */
    unsigned char *verifier = NULL;
    int vlen = 0;
    int ret = srp_create_salt_verifier(SRP_USERNAME,
                                        (const unsigned char *)ctx->pin, strlen(ctx->pin),
                                        ctx->srp_salt, &verifier, &vlen);
    if (ret != 0) {
        printf("[PAIR] ERROR: srp_create_salt_verifier failed\n");
        return make_error_response(2, 1, out_len);  /* Unknown error */
    }

    ctx->srp_verifier = verifier;
    ctx->srp_verifier_len = vlen;

    /* Generate random server private ephemeral key (b) */
    srp_init_random();
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(ctx->srp_b),
                           ctx->srp_b) != errSecSuccess) {
        printf("[PAIR] ERROR: secure random generation failed\n");
        return make_error_response(2, 1, out_len);
    }

    /* Compute server public ephemeral key (B) */
    unsigned char *B = NULL;
    int B_len = 0;
    ret = srp_create_B(verifier, vlen, ctx->srp_b, 32, &B, &B_len);
    if (ret != 0 || !B) {
        printf("[PAIR] ERROR: srp_create_B failed\n");
        return make_error_response(2, 1, out_len);
    }

    printf("[PAIR] SRP salt (%d): ", SRP_SALT_BYTES);
    for (int i = 0; i < SRP_SALT_BYTES; i++) printf("%02x", ctx->srp_salt[i]);
    printf("\n");
    printf("[PAIR] SRP B (%d bytes)\n", B_len);

    /* Build M2 response: State=2, Salt, PublicKey */
    uint8_t state = 2;
    tlv_item_t items[3] = {
        { TLV_STATE,      &state,        1 },
        { TLV_SALT,       ctx->srp_salt, SRP_SALT_BYTES },
        { TLV_PUBLIC_KEY, B,             (size_t)B_len }
    };
    uint8_t *resp = tlv_build(items, 3, out_len);
    free(B);

    ctx->setup_state = 2;
    printf("[PAIR] pair-setup M2 sent (State=2, Salt=%d, PK=%d, total=%zu)\n",
           SRP_SALT_BYTES, B_len, *out_len);
    return resp;
}

/* M3 → M4: Verify client proof, send server proof */
static uint8_t *handle_setup_m3(pair_ctx_t *ctx, const tlv_t *in, size_t *out_len) {
    printf("[PAIR] pair-setup M3 received (State=3)\n");

    const tlv_item_t *pk_item = tlv_find(in, TLV_PUBLIC_KEY);
    const tlv_item_t *proof_item = tlv_find(in, TLV_PROOF);

    if (!pk_item || !proof_item) {
        printf("[PAIR] ERROR: M3 missing PublicKey or Proof\n");
        return make_error_response(4, 2, out_len);  /* Auth error */
    }

    printf("[PAIR] SRP A len=%zu, client proof len=%zu\n",
           pk_item->len, proof_item->len);

    if (proof_item->len != SRP_HASH_LEN) {
        printf("[PAIR] ERROR: Client proof wrong size (got %zu, expected %d)\n",
               proof_item->len, SRP_HASH_LEN);
        return make_error_response(4, 2, out_len);
    }

    /* Create SRP verifier with client's A and our stored b/salt/verifier */
    srp_verifier_t *ver = srp_verifier_new(SRP_USERNAME,
                                             ctx->srp_salt, SRP_SALT_BYTES,
                                             ctx->srp_verifier, ctx->srp_verifier_len,
                                             pk_item->data, pk_item->len,
                                             ctx->srp_b, 32);
    if (!ver) {
        printf("[PAIR] ERROR: srp_verifier_new failed (SRP-6a safety check?)\n");
        return make_error_response(4, 2, out_len);
    }
    if ((int)pk_item->len < ver->N_len) {
        printf("[PAIR] client public key A shorter than N (%zu < %d); padded compatibility path available\n",
               pk_item->len, ver->N_len);
    }

    /* Verify client's proof */
    const unsigned char *server_M2 = NULL;
    int vret = srp_verifier_verify(ver, proof_item->data, &server_M2);
    if (vret != 0 || !server_M2) {
        printf("[PAIR] ERROR: SRP proof verification failed after minimal and padded KDF checks\n");
        srp_verifier_delete(ver);
        return make_error_response(4, 2, out_len);
    }

    printf("[PAIR] *** SRP proof verification SUCCEEDED mode=%s ***\n",
           ver->proof_mode == 2 ? "padded-S" : "minimal-S");

    /* Save session key */
    memcpy(ctx->srp_session_key, ver->session_key, SRP_SKEY_LEN);
    ctx->srp_has_session_key = 1;

    printf("[PAIR] Session key established (%d bytes)\n", SRP_SKEY_LEN);

    /* Build M4 response: State=4, Proof */
    uint8_t state = 4;
    tlv_item_t items[2] = {
        { TLV_STATE, &state, 1 },
        { TLV_PROOF, (uint8_t *)server_M2, SRP_HASH_LEN }
    };
    uint8_t *resp = tlv_build(items, 2, out_len);
    srp_verifier_delete(ver);

    ctx->setup_state = 4;
    printf("[PAIR] pair-setup M4 sent (State=4, Proof=%d)\n", SRP_HASH_LEN);
    return resp;
}

/* M5 → M6: Decrypt client sub-TLV, encrypt our sub-TLV.
 * Uses HKDF-SHA512 key derivation + ChaCha20-Poly1305 encryption.
 * Nonces: "PS-Msg05" for M5 decrypt, "PS-Msg06" for M6 encrypt. */
static uint8_t *handle_setup_m5(pair_ctx_t *ctx, const tlv_t *in, size_t *out_len) {
    printf("[PAIR] pair-setup M5 received (State=5)\n");

    if (!ctx->srp_has_session_key) {
        printf("[PAIR] ERROR: No session key (M4 not completed?)\n");
        return make_error_response(6, 2, out_len);
    }

    const tlv_item_t *enc_item = tlv_find(in, TLV_ENCRYPTED_DATA);
    if (!enc_item) {
        printf("[PAIR] ERROR: M5 missing EncryptedData\n");
        return make_error_response(6, 2, out_len);
    }

    printf("[PAIR] M5 EncryptedData: %zu bytes\n", enc_item->len);

    /* Derive 32-byte encryption key via HKDF-SHA512 */
    unsigned char enc_key[32];
    derive_pair_setup_encrypt_key(ctx->srp_session_key, SRP_SKEY_LEN, enc_key);

    printf("[PAIR] Pair-setup encryption key derived\n");

    if (enc_item->len < 16 + 1) {
        printf("[PAIR] ERROR: EncryptedData too short (%zu)\n", enc_item->len);
        return make_error_response(6, 2, out_len);
    }

    int ct_len = (int)enc_item->len - 16;
    unsigned char *ciphertext = enc_item->data;
    unsigned char *auth_tag = enc_item->data + ct_len;
    unsigned char *plaintext = malloc(ct_len);
    if (!plaintext) return make_error_response(6, 1, out_len);

    printf("[PAIR] ChaCha20-Poly1305 decrypt: ct=%d, nonce=PS-Msg05\n", ct_len);

    int pt_len = chacha_decrypt(enc_key, (const unsigned char *)"PS-Msg05",
                                 ciphertext, ct_len, plaintext, auth_tag);
    if (pt_len <= 0) {
        printf("[PAIR] ERROR: ChaCha20-Poly1305 decryption FAILED\n");
        free(plaintext);
        return make_error_response(6, 2, out_len);
    }

    printf("[PAIR] Decrypted %d bytes (sub-TLV)\n", pt_len);

    /* Parse sub-TLV: Identifier + PublicKey + Signature */
    tlv_t *sub = tlv_parse(plaintext, pt_len);
    if (sub) {
        const tlv_item_t *pk = tlv_find(sub, TLV_PUBLIC_KEY);
        const tlv_item_t *ident = tlv_find(sub, TLV_IDENTIFIER);
        const tlv_item_t *sig = tlv_find(sub, TLV_SIGNATURE);

        if (ident) {
            printf("[PAIR]   Identifier (%zu): %.*s\n",
                   ident->len, (int)ident->len, ident->data);
        }
        if (pk && pk->len >= ED25519_KEY_LEN) {
            memcpy(ctx->client_pk, pk->data, ED25519_KEY_LEN);
            ctx->client_pk_set = 1;
            printf("[PAIR]   Client Ed25519 pk: ");
            for (int i = 0; i < ED25519_KEY_LEN; i++) printf("%02x", ctx->client_pk[i]);
            printf("\n");
            if (ident && pair_ctx_add_peer(ctx, ident->data, ident->len,
                                          ctx->client_pk) == 0) {
                printf("[PAIR]   Controller saved in registry (%zu total)\n",
                       ctx->peer_count);
            }
        }
        if (sig) {
            printf("[PAIR]   Signature (%zu bytes)\n", sig->len);
        }
        if (!ctx->client_pk_set) {
            printf("[PAIR] ERROR: No PublicKey found in sub-TLV\n");
        }
        tlv_free(sub);
    } else {
        /* Try raw Ed25519 pk format (fallback) */
        if (pt_len == ED25519_KEY_LEN) {
            memcpy(ctx->client_pk, plaintext, ED25519_KEY_LEN);
            ctx->client_pk_set = 1;
            printf("[PAIR] Client Ed25519 pk (raw 32 bytes)\n");
        } else {
            printf("[PAIR] ERROR: Failed to parse sub-TLV and not raw pk\n");
        }
    }
    free(plaintext);

    if (!ctx->client_pk_set) {
        printf("[PAIR] ERROR: Could not extract client Ed25519 pk\n");
        return make_error_response(6, 2, out_len);
    }

    /* Build M6 sub-TLV: Identifier + PublicKey + Signature.
     * Signature = Ed25519_sign(accessoryX || Identifier || our_pk)
     * accessoryX = HKDF-SHA512(session_key,
     *   salt="Pair-Setup-Accessory-Sign-Salt",
     *   info="Pair-Setup-Accessory-Sign-Info")[:32] */

    /* Derive accessoryX for signing */
    unsigned char accessoryX[32];
    hkdf_sha512(ctx->srp_session_key, SRP_SKEY_LEN,
                (const unsigned char *)"Pair-Setup-Accessory-Sign-Salt", 30,
                (const unsigned char *)"Pair-Setup-Accessory-Sign-Info", 30,
                accessoryX, 32);

    /* Our identifier — use DeviceID MAC */
    uint8_t m6_ident[] = "90:B9:31:AC:86:A0";
    int m6_ident_len = sizeof(m6_ident) - 1;  /* 17 bytes */

    /* Build signing message: accessoryX || Identifier || our_pk */
    int sign_msg_len = 32 + m6_ident_len + ED25519_KEY_LEN;
    unsigned char *sign_msg = malloc(sign_msg_len);
    memcpy(sign_msg, accessoryX, 32);
    memcpy(sign_msg + 32, m6_ident, m6_ident_len);
    memcpy(sign_msg + 32 + m6_ident_len, ctx->our_pk, ED25519_KEY_LEN);

    /* Ed25519 sign */
    unsigned char signature[64];
    size_t sig_len = 64;
    uint8_t signingSeed[32];
    uint8_t signingSecret[64];
    uint8_t signingPublic[32];
    memcpy(signingSeed, ctx->our_sk, sizeof(signingSeed));
    crypto_ed25519_key_pair(signingSecret, signingPublic, signingSeed);
    crypto_ed25519_sign(signature, signingSecret, sign_msg,
                        (size_t)sign_msg_len);
    crypto_wipe(signingSecret, sizeof(signingSecret));
    crypto_wipe(signingPublic, sizeof(signingPublic));
    printf("[PAIR] M6 Ed25519 signature computed (%zu bytes)\n", sig_len);
    free(sign_msg);

    tlv_item_t sub_items[3] = {
        { TLV_IDENTIFIER, m6_ident,      (size_t)m6_ident_len },
        { TLV_PUBLIC_KEY, ctx->our_pk,    ED25519_KEY_LEN },
        { TLV_SIGNATURE,  signature,      (size_t)sig_len }
    };

    size_t sub_len = 0;
    uint8_t *sub_buf = tlv_build(sub_items, 3, &sub_len);
    if (!sub_buf) return make_error_response(6, 1, out_len);

    printf("[PAIR] M6 sub-TLV: %zu bytes\n", sub_len);

    /* Encrypt with ChaCha20-Poly1305 using "PS-Msg06" nonce */
    unsigned char *enc_ct = malloc(sub_len);
    unsigned char enc_tag[16];
    if (!enc_ct) { free(sub_buf); return make_error_response(6, 1, out_len); }

    int enc_len = chacha_encrypt(enc_key, (const unsigned char *)"PS-Msg06",
                                  sub_buf, (int)sub_len, enc_ct, enc_tag);
    free(sub_buf);
    if (enc_len <= 0) {
        printf("[PAIR] ERROR: ChaCha20-Poly1305 encryption failed\n");
        free(enc_ct);
        return make_error_response(6, 1, out_len);
    }

    /* Build EncryptedData: ciphertext + tag */
    size_t enc_out_len = enc_len + 16;
    unsigned char *enc_out = malloc(enc_out_len);
    if (!enc_out) { free(enc_ct); return make_error_response(6, 1, out_len); }
    memcpy(enc_out, enc_ct, enc_len);
    memcpy(enc_out + enc_len, enc_tag, 16);
    free(enc_ct);

    /* Build M6 response: State=6, EncryptedData */
    uint8_t state = 6;
    tlv_item_t resp_items[2] = {
        { TLV_STATE,          &state,  1 },
        { TLV_ENCRYPTED_DATA, enc_out, enc_out_len }
    };
    uint8_t *resp = tlv_build(resp_items, 2, out_len);
    free(enc_out);

    ctx->setup_state = 6;
    printf("[PAIR] *** PAIR-SETUP COMPLETE ***\n");
    printf("[PAIR] pair-setup M6 sent (State=6, EncryptedData=%zu)\n", enc_out_len);
    return resp;
}

/* Main pair-setup dispatcher */
uint8_t *pair_setup_handle(pair_ctx_t *ctx, const uint8_t *body, size_t bodyLen,
                            size_t *out_len) {
    *out_len = 0;
    if (!ctx || !body || bodyLen == 0) return NULL;

    tlv_t *in = tlv_parse(body, bodyLen);
    if (!in) {
        printf("[PAIR] ERROR: Failed to parse TLV8\n");
        return NULL;
    }

    /* Extract State */
    const tlv_item_t *state_item = tlv_find(in, TLV_STATE);
    if (!state_item || state_item->len != 1) {
        printf("[PAIR] ERROR: No State TLV in pair-setup request\n");
        tlv_free(in);
        return NULL;
    }

    uint8_t state = state_item->data[0];
    uint8_t *resp = NULL;

    printf("[PAIR] pair-setup: incoming State=%d\n", state);

    switch (state) {
        case 1:  /* M1 */
            resp = handle_setup_m1(ctx, in, out_len);
            break;
        case 3:  /* M3 */
            resp = handle_setup_m3(ctx, in, out_len);
            break;
        case 5:  /* M5 */
            resp = handle_setup_m5(ctx, in, out_len);
            break;
        default:
            printf("[PAIR] ERROR: Unexpected pair-setup state %d\n", state);
            resp = make_error_response(state + 1, 1, out_len);
            break;
    }

    tlv_free(in);
    return resp;
}

/* ═══════════════════════════════════════════════════════════════
 * 8. Pair-Verify Handler (M1→M4)
 *    X25519 and standard Ed25519 are provided by embedded Monocypher.
 * ═══════════════════════════════════════════════════════════════ */

/* M1 → M2: Generate X25519 ECDH, sign with Ed25519, send encrypted signature */
static uint8_t *handle_verify_m1(pair_ctx_t *ctx, const tlv_t *in, size_t *out_len) {
    printf("[PAIR] pair-verify M1 received (State=1)\n");

    const tlv_item_t *pk_item = tlv_find(in, TLV_PUBLIC_KEY);
    if (!pk_item || pk_item->len != 32) {
        printf("[PAIR] ERROR: M1 missing or invalid PublicKey (len=%zu)\n",
               pk_item ? pk_item->len : 0);
        return make_error_response(2, 2, out_len);
    }

    printf("[PAIR] Client X25519 pk: ");
    for (int i = 0; i < 32; i++) printf("%02x", pk_item->data[i]);
    printf("\n");

    /* Store client's X25519 pk for M3 signature verification */
    memcpy(ctx->client_ecdh_pk, pk_item->data, 32);
    ctx->client_ecdh_pk_set = 1;

    /* Generate our X25519 keypair. */
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(ctx->verify_ecdh_sk),
                           ctx->verify_ecdh_sk) != errSecSuccess) {
        printf("[PAIR] ERROR: X25519 secure random generation failed\n");
        return make_error_response(2, 1, out_len);
    }

    unsigned char our_ecdh_pk[32];
    crypto_x25519_public_key(our_ecdh_pk, ctx->verify_ecdh_sk);

    printf("[PAIR] Our X25519 pk: ");
    for (int i = 0; i < 32; i++) printf("%02x", our_ecdh_pk[i]);
    printf("\n");

    /* ECDH shared secret */
    crypto_x25519(ctx->verify_shared, ctx->verify_ecdh_sk, pk_item->data);
    static const uint8_t zeroSecret[32] = {0};
    if (crypto_verify32(ctx->verify_shared, zeroSecret) == 0) {
        printf("[PAIR] ERROR: X25519 produced an invalid all-zero secret\n");
        return make_error_response(2, 2, out_len);
    }

    printf("[PAIR] ECDH shared secret established\n");

    /* Save our ECDH public key for M3 */
    memcpy(ctx->verify_our_ecdh_pk, our_ecdh_pk, 32);

    /* Sign: Ed25519_sign(our_ecdh_pk || identifier || client_ecdh_pk) */
    const char *our_ident = "90:B9:31:AC:86:A0";
    int our_ident_len = 17;
    int sig_msg_len = 32 + our_ident_len + 32;
    unsigned char *sig_msg = malloc(sig_msg_len);
    if (!sig_msg) return make_error_response(2, 1, out_len);
    memcpy(sig_msg, our_ecdh_pk, 32);
    memcpy(sig_msg + 32, our_ident, our_ident_len);
    memcpy(sig_msg + 32 + our_ident_len, pk_item->data, 32);

    unsigned char signature[64];
    size_t sig_len = sizeof(signature);
    uint8_t signingSeed[32];
    uint8_t signingSecret[64];
    uint8_t signingPublic[32];
    memcpy(signingSeed, ctx->our_sk, sizeof(signingSeed));
    crypto_ed25519_key_pair(signingSecret, signingPublic, signingSeed);
    crypto_ed25519_sign(signature, signingSecret, sig_msg,
                        (size_t)sig_msg_len);
    crypto_wipe(signingSecret, sizeof(signingSecret));
    crypto_wipe(signingPublic, sizeof(signingPublic));
    free(sig_msg);

    printf("[PAIR] Ed25519 signature (%zu bytes)\n", sig_len);

    /* Build sub-TLV: Identifier + Signature */
    tlv_item_t sub_items[2] = {
        { TLV_IDENTIFIER, (uint8_t *)our_ident,       (size_t)our_ident_len },
        { TLV_SIGNATURE,  signature,                  sig_len }
    };
    size_t sub_len = 0;
    uint8_t *sub_buf = tlv_build(sub_items, 2, &sub_len);
    if (!sub_buf) return make_error_response(2, 1, out_len);

    printf("[PAIR] M2 sub-TLV: %zu bytes (Identifier=%d + Signature=%zu)\n",
           sub_len, our_ident_len, sig_len);

    /* Derive encryption key: HKDF-SHA512(shared_secret,
     *   salt="Pair-Verify-Encrypt-Salt", info="Pair-Verify-Encrypt-Info") */
    hkdf_sha512(ctx->verify_shared, 32,
                (const unsigned char *)"Pair-Verify-Encrypt-Salt", 24,
                (const unsigned char *)"Pair-Verify-Encrypt-Info", 24,
                ctx->verify_enc_key, 32);

    printf("[PAIR] Pair-verify encryption key derived\n");

    /* Encrypt sub-TLV with ChaCha20-Poly1305, nonce="PV-Msg02" */
    unsigned char *enc_ct = malloc(sub_len);
    unsigned char enc_tag[16];
    if (!enc_ct) { free(sub_buf); return make_error_response(2, 1, out_len); }

    int enc_len = chacha_encrypt(ctx->verify_enc_key,
                                  (const unsigned char *)"PV-Msg02",
                                  sub_buf, (int)sub_len, enc_ct, enc_tag);
    free(sub_buf);
    if (enc_len <= 0) {
        printf("[PAIR] ERROR: ChaCha20 encrypt failed for M2\n");
        free(enc_ct);
        return make_error_response(2, 1, out_len);
    }

    /* EncryptedData = ciphertext + 16-byte auth tag */
    size_t enc_total = enc_len + 16;
    unsigned char *enc_out = malloc(enc_total);
    if (!enc_out) { free(enc_ct); return make_error_response(2, 1, out_len); }
    memcpy(enc_out, enc_ct, enc_len);
    memcpy(enc_out + enc_len, enc_tag, 16);
    free(enc_ct);

    printf("[PAIR] M2 EncryptedData: %zu bytes (ct=%d + tag=16)\n", enc_total, enc_len);

    /* Build M2 response: State=2, PublicKey(our X25519), EncryptedData */
    uint8_t state = 2;
    tlv_item_t items[3] = {
        { TLV_STATE,          &state,     1 },
        { TLV_PUBLIC_KEY,     our_ecdh_pk, 32 },
        { TLV_ENCRYPTED_DATA, enc_out,    enc_total }
    };
    uint8_t *resp = tlv_build(items, 3, out_len);
    free(enc_out);

    ctx->verify_state = 2;
    printf("[PAIR] pair-verify M2 sent (State=2, PK=32, EncData=%zu)\n", enc_total);
    return resp;
}

/* M3 → M4: Decrypt + verify client's signature */
static uint8_t *handle_verify_m3(pair_ctx_t *ctx, const tlv_t *in, size_t *out_len) {
    printf("[PAIR] pair-verify M3 received (State=3)\n");

    const tlv_item_t *enc_item = tlv_find(in, TLV_ENCRYPTED_DATA);
    if (!enc_item || enc_item->len < 16) {
        printf("[PAIR] ERROR: M3 missing or short EncryptedData (len=%zu)\n",
               enc_item ? enc_item->len : 0);
        return make_error_response(4, 2, out_len);
    }

    /* EncryptedData = ciphertext + 16-byte auth tag */
    int ct_len = (int)enc_item->len - 16;
    const unsigned char *ct = enc_item->data;
    const unsigned char *tag = enc_item->data + ct_len;

    printf("[PAIR] M3 EncryptedData: %zu bytes (ct=%d + tag=16)\n", enc_item->len, ct_len);

    /* Decrypt with ChaCha20-Poly1305, nonce="PV-Msg03", same key as M2 */
    unsigned char *pt = malloc(ct_len);
    if (!pt) return make_error_response(4, 1, out_len);

    int pt_len = chacha_decrypt(ctx->verify_enc_key,
                                 (const unsigned char *)"PV-Msg03",
                                 ct, ct_len, pt, tag);
    if (pt_len < 0) {
        printf("[PAIR] ERROR: ChaCha20-Poly1305 decrypt FAILED for M3\n");
        free(pt);
        return make_error_response(4, 2, out_len);
    }

    printf("[PAIR] Decrypted M3 sub-TLV: %d bytes\n", pt_len);

    /* Parse sub-TLV: Identifier + Signature */
    tlv_t *sub_tlv = tlv_parse(pt, pt_len);
    free(pt);
    if (!sub_tlv) {
        printf("[PAIR] ERROR: Failed to parse M3 sub-TLV\n");
        return make_error_response(4, 2, out_len);
    }

    const tlv_item_t *ident_item = tlv_find(sub_tlv, TLV_IDENTIFIER);
    const tlv_item_t *sig_item = tlv_find(sub_tlv, TLV_SIGNATURE);

    if (!ident_item) {
        printf("[PAIR] ERROR: M3 sub-TLV missing Identifier\n");
        tlv_free(sub_tlv);
        return make_error_response(4, 2, out_len);
    }
    if (!sig_item || sig_item->len != 64) {
        printf("[PAIR] ERROR: M3 sub-TLV missing or invalid Signature (len=%zu)\n",
               sig_item ? sig_item->len : 0);
        tlv_free(sub_tlv);
        return make_error_response(4, 2, out_len);
    }

    printf("[PAIR]   Client identifier (%zu): %.*s\n",
           ident_item->len, (int)ident_item->len, ident_item->data);
    printf("[PAIR]   Client signature (64 bytes)\n");

    /* Verify against the identifier-specific key restored from persistent
     * storage. A just-completed pair-setup has populated the same registry. */
    int peer_index = find_peer_index(ctx, ident_item->data, ident_item->len);
    const uint8_t *verify_pk = peer_index >= 0
        ? ctx->peers[peer_index].public_key
        : (ctx->client_pk_set ? ctx->client_pk : NULL);
    bool signature_valid = false;
    if (verify_pk && ctx->client_ecdh_pk_set) {
        int verify_msg_len = 32 + (int)ident_item->len + 32;
        unsigned char *verify_msg = malloc(verify_msg_len);
        if (verify_msg) {
            memcpy(verify_msg, ctx->client_ecdh_pk, 32);
            memcpy(verify_msg + 32, ident_item->data, ident_item->len);
            memcpy(verify_msg + 32 + ident_item->len, ctx->verify_our_ecdh_pk, 32);

            int vret = crypto_ed25519_check(
                sig_item->data, verify_pk, verify_msg,
                (size_t)verify_msg_len);
            if (vret == 0) {
                printf("[PAIR] *** Ed25519 signature verification PASSED ***\n");
                signature_valid = true;
            } else {
                printf("[PAIR] ERROR: Ed25519 signature verification FAILED\n");
            }
            free(verify_msg);
        }
    } else {
        printf("[PAIR] WARNING: Skipping signature verification ");
        if (!verify_pk) printf("(identifier is not paired) ");
        if (!ctx->client_ecdh_pk_set) printf("(no client ECDH pk) ");
        printf("\n");
    }

    tlv_free(sub_tlv);
    if (!signature_valid) {
        printf("[PAIR] Rejecting unpaired or unauthenticated controller\n");
        return make_error_response(4, 2, out_len);
    }

    /* Build M4 response: State=4 (success) */
    uint8_t state = 4;
    tlv_item_t items[1] = {
        { TLV_STATE, &state, 1 }
    };
    uint8_t *resp = tlv_build(items, 1, out_len);

    ctx->verify_state = 4;
    printf("[PAIR] *** PAIR-VERIFY COMPLETE ***\n");
    printf("[PAIR] pair-verify M4 sent (State=4, success)\n");
    return resp;
}

/* Main pair-verify dispatcher */
uint8_t *pair_verify_handle(pair_ctx_t *ctx, const uint8_t *body, size_t bodyLen,
                              size_t *out_len) {
    *out_len = 0;
    if (!ctx || !body || bodyLen == 0) return NULL;

    tlv_t *in = tlv_parse(body, bodyLen);
    if (!in) {
        printf("[PAIR] ERROR: Failed to parse TLV8\n");
        return NULL;
    }

    const tlv_item_t *state_item = tlv_find(in, TLV_STATE);
    if (!state_item || state_item->len != 1) {
        printf("[PAIR] ERROR: No State TLV in pair-verify request\n");
        tlv_free(in);
        return NULL;
    }

    uint8_t state = state_item->data[0];
    uint8_t *resp = NULL;

    printf("[PAIR] pair-verify: incoming State=%d\n", state);

    switch (state) {
        case 1:
            resp = handle_verify_m1(ctx, in, out_len);
            break;
        case 3:
            resp = handle_verify_m3(ctx, in, out_len);
            break;
        default:
            printf("[PAIR] ERROR: Unexpected pair-verify state %d\n", state);
            resp = make_error_response(state + 1, 1, out_len);
            break;
    }

    tlv_free(in);
    return resp;
}

/* ═══════════════════════════════════════════════════════════════
 * 9. Public API — status checks
 * ═══════════════════════════════════════════════════════════════ */

bool pair_setup_is_complete(pair_ctx_t *ctx) {
    return ctx && ctx->setup_state == 6;
}

bool pair_verify_is_complete(pair_ctx_t *ctx) {
    return ctx && ctx->verify_state == 4;
}
