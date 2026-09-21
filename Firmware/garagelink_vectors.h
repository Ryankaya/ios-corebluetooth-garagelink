// GarageLink protocol v1 — cross-implementation test vectors.
//
// Generated from the Swift implementation (Packages/GarageKit) and asserted there by
// CrossImplementationVectors.swift. The ESP32 firmware runs the same checks at boot in debug
// builds: if mbedTLS doesn't reproduce these bytes, pairing with the iPhone app cannot work.
//
// All values are hex, most-significant byte first.

#pragma once

#define GL_VEC_SETUP_CODE      "080111"
#define GL_VEC_DEVICE_ID       "289e9ade2bece609"   // 8 bytes
#define GL_VEC_CLIENT_ID       "8a649b4f1c2d3e40"   // 8 bytes

// P-256 private scalars (32 bytes each)
#define GL_VEC_DEVICE_PRIVATE  "c9f8a1d4b7e20356914af08d2c6b5e73a1d90f4c82b6e5379d0c1a4fb82e6935"
#define GL_VEC_CLIENT_PRIVATE  "3b7d1e9c05a4f82671d3c05e9b4a72f18d6c30594ea7b1c82f0d5936ae41c70b"

// Uncompressed public keys (65 bytes, 0x04 || X || Y)
#define GL_VEC_DEVICE_PUBLIC   "04782d76c4234aa6025918b40700c09891b5f3d5b50ac9f3f8f96bcc33ea7654dc7e467ca0963318f575c1455ee543cb66752beaf1a795f0332c5f7d9b58f0183d"
#define GL_VEC_CLIENT_PUBLIC   "04192785789a8d7623abc607a895889e4359121722041a1bd2632592098e8395e1e138802c90aa814247a8a37a0512bbaf9c429acb2a13a185df57e52a300ba454"

// HKDF inputs
#define GL_VEC_SALT            "0f1e2d3c4b5a69788796a5b4c3d2e1f0"   // 16 bytes
// info = "GarageLink-v1" || setup code ascii || client id || device id

// Expected results
// 1. ECDH P-256 shared secret (X coordinate) -> HKDF-SHA256(salt, info) -> 32-byte session key
#define GL_VEC_SESSION_KEY     "a43b125eb6736dd5b4e1a16dc437af30b37f31340e4134ce28d40c9294becb8f"
// 2. HMAC-SHA256(key, "GLPAIR" || client public || device public), first 16 bytes
#define GL_VEC_PAIRING_TAG     "ad5b390ad29fa358b55d3c52703437f1"
// 3. HMAC-SHA256(key, "GLCMD" || opcode || challenge || device id || client id), first 16 bytes
#define GL_VEC_CHALLENGE       "11223344556677889900aabbccddeeff"   // 16 bytes
#define GL_VEC_COMMAND_OPCODE  0x01                                  // OPEN
#define GL_VEC_COMMAND_TAG     "fc4718666343842c441b05c5e787f4ae"
// 4. Full Command frame written to the Command characteristic: opcode || client id || tag
#define GL_VEC_COMMAND_FRAME   "018a649b4f1c2d3e40fc4718666343842c441b05c5e787f4ae"
