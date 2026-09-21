#pragma once

#include "gl_protocol.h"

// ECDH P-256: generates a key pair, returning the 32-byte private scalar and 65-byte
// uncompressed public key (0x04 || X || Y), matching CryptoKit's x963Representation.
int gl_ecdh_generate(uint8_t private_scalar[GL_KEY_LEN], uint8_t public_key[GL_PUBKEY_LEN]);

// Shared secret = X coordinate of (private * peer_public), the same value CryptoKit hands to HKDF.
int gl_ecdh_shared(const uint8_t private_scalar[GL_KEY_LEN],
                   const uint8_t peer_public[GL_PUBKEY_LEN],
                   uint8_t shared[GL_KEY_LEN]);

int gl_public_key_is_valid(const uint8_t public_key[GL_PUBKEY_LEN]);

// HKDF-SHA256 with info = "GarageLink-v1" || setup code || client id || device id.
void gl_derive_session_key(const uint8_t shared[GL_KEY_LEN],
                           const uint8_t salt[GL_SALT_LEN],
                           const char *setup_code,
                           const uint8_t client_id[GL_ID_LEN],
                           const uint8_t device_id[GL_ID_LEN],
                           uint8_t key[GL_KEY_LEN]);

// HMAC-SHA256("GLPAIR" || client public || device public), truncated to 16 bytes.
void gl_pairing_tag(const uint8_t key[GL_KEY_LEN],
                    const uint8_t client_public[GL_PUBKEY_LEN],
                    const uint8_t device_public[GL_PUBKEY_LEN],
                    uint8_t tag[GL_TAG_LEN]);

// HMAC-SHA256("GLCMD" || opcode || challenge || device id || client id), truncated to 16 bytes.
void gl_command_tag(const uint8_t key[GL_KEY_LEN], uint8_t opcode,
                    const uint8_t challenge[GL_CHALLENGE_LEN],
                    const uint8_t device_id[GL_ID_LEN],
                    const uint8_t client_id[GL_ID_LEN],
                    uint8_t tag[GL_TAG_LEN]);

bool gl_constant_time_equal(const uint8_t *a, const uint8_t *b, size_t len);
void gl_random_bytes(uint8_t *out, size_t len);
void gl_hex_to_bytes(const char *hex, uint8_t *out, size_t out_len);
void gl_bytes_to_hex(const uint8_t *bytes, size_t len, char *out);
