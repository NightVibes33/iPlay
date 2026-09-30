/*
 * carplay_pair.h — Apple AirPlay pair-setup (SRP-6a) & pair-verify
 *
 * Implements the HomeKit-style pairing used by AirPlay 2 / wireless CarPlay:
 *   Pair-setup: SRP-6a (M1→M6) + ChaCha20-Poly1305 key exchange
 *   Pair-verify: X25519 ECDH + Ed25519 signatures (M1→M4)
 *
 * Crypto dependencies are embedded in source/vendor.
 */

#ifndef CARPLAY_PAIR_H
#define CARPLAY_PAIR_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Pair context — opaque, holds all pairing state */
typedef struct pair_ctx_s pair_ctx_t;

/* Create pair context.
 * sk: our Ed25519 secret key seed (32 bytes)
 * pk: our Ed25519 public key (32 bytes)
 * pin: SRP password (e.g. "3939"), NULL = use default "3939" */
pair_ctx_t *pair_ctx_create(const uint8_t sk[32], const uint8_t pk[32], const char *pin);

/* Handle POST /pair-setup body.
 * body/bodyLen: incoming TLV8 data from iPhone.
 * Returns response TLV8 data (caller must free), or NULL on error.
 * *out_len is set to response length. */
uint8_t *pair_setup_handle(pair_ctx_t *ctx, const uint8_t *body, size_t bodyLen, size_t *out_len);

/* Handle POST /pair-verify body. */
uint8_t *pair_verify_handle(pair_ctx_t *ctx, const uint8_t *body, size_t bodyLen, size_t *out_len);

/* True if pair-setup completed successfully (M6 sent) */
bool pair_setup_is_complete(pair_ctx_t *ctx);

/* True if pair-verify completed successfully (M4 sent) */
bool pair_verify_is_complete(pair_ctx_t *ctx);

/* Persisted controller registry. Pair-setup adds or refreshes a controller;
 * callers can serialize the registry and restore it in a new process so
 * returning iPhones can use pair-verify without repeating pair-setup. */
int pair_ctx_add_peer(pair_ctx_t *ctx, const uint8_t *identifier,
                      size_t identifier_len, const uint8_t public_key[32]);
size_t pair_ctx_peer_count(const pair_ctx_t *ctx);
int pair_ctx_get_peer(const pair_ctx_t *ctx, size_t index,
                      uint8_t *identifier, size_t identifier_capacity,
                      size_t *identifier_len, uint8_t public_key[32]);

/* Derive control channel encryption keys after pair-verify.
 * readKey: 32 bytes — decrypt iPhone→us (HKDF "Control-Write-Encryption-Key")
 * writeKey: 32 bytes — encrypt us→iPhone (HKDF "Control-Read-Encryption-Key")
 * Returns 0 on success, -1 on error. */
int pair_derive_control_keys(pair_ctx_t *ctx, uint8_t readKey[32], uint8_t writeKey[32]);

/* Derive event channel encryption keys after pair-verify.
 * readKey: 32 bytes — decrypt iPhone→us (HKDF "Events-Write-Encryption-Key")
 * writeKey: 32 bytes — encrypt us→iPhone (HKDF "Events-Read-Encryption-Key")
 * Returns 0 on success, -1 on error. */
int pair_derive_event_keys(pair_ctx_t *ctx, uint8_t readKey[32], uint8_t writeKey[32]);

/* Derive stream encryption key for screen/audio data.
 * streamConnectionID: from SETUP Phase 2 streams array.
 * outKey: 32 bytes — ChaCha20-Poly1305 key to decrypt incoming stream data.
 * Salt = "DataStream-Salt" + decimal(streamConnectionID)
 * Info = "DataStream-Output-Encryption-Key"
 * Returns 0 on success, -1 on error. */
int pair_derive_stream_key(pair_ctx_t *ctx, uint64_t streamConnectionID, uint8_t outKey[32]);

/* Destroy pair context and free all resources */
void pair_ctx_destroy(pair_ctx_t *ctx);

#endif /* CARPLAY_PAIR_H */
