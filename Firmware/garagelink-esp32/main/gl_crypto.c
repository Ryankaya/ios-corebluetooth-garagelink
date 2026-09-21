#include "gl_crypto.h"

#include <string.h>

#include "esp_random.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/ecp.h"
#include "mbedtls/md.h"

static int rng_wrapper(void *ctx, unsigned char *out, size_t len)
{
    (void)ctx;
    esp_fill_random(out, len);
    return 0;
}

void gl_random_bytes(uint8_t *out, size_t len)
{
    esp_fill_random(out, len);
}

int gl_ecdh_generate(uint8_t private_scalar[GL_KEY_LEN], uint8_t public_key[GL_PUBKEY_LEN])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);

    int rc = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (rc == 0) rc = mbedtls_ecdh_gen_public(&grp, &d, &Q, rng_wrapper, NULL);
    if (rc == 0) rc = mbedtls_mpi_write_binary(&d, private_scalar, GL_KEY_LEN);
    size_t olen = 0;
    if (rc == 0) {
        rc = mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen,
                                            public_key, GL_PUBKEY_LEN);
    }
    if (rc == 0 && olen != GL_PUBKEY_LEN) rc = -1;

    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return rc;
}

int gl_ecdh_shared(const uint8_t private_scalar[GL_KEY_LEN],
                   const uint8_t peer_public[GL_PUBKEY_LEN],
                   uint8_t shared[GL_KEY_LEN])
{
    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);

    int rc = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (rc == 0) rc = mbedtls_mpi_read_binary(&d, private_scalar, GL_KEY_LEN);
    if (rc == 0) rc = mbedtls_ecp_point_read_binary(&grp, &Q, peer_public, GL_PUBKEY_LEN);
    if (rc == 0) rc = mbedtls_ecp_check_pubkey(&grp, &Q);
    if (rc == 0) rc = mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, rng_wrapper, NULL);
    if (rc == 0) rc = mbedtls_mpi_write_binary(&z, shared, GL_KEY_LEN);

    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    return rc;
}

int gl_public_key_is_valid(const uint8_t public_key[GL_PUBKEY_LEN])
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_point_init(&Q);
    int rc = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    if (rc == 0) rc = mbedtls_ecp_point_read_binary(&grp, &Q, public_key, GL_PUBKEY_LEN);
    if (rc == 0) rc = mbedtls_ecp_check_pubkey(&grp, &Q);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
    return rc == 0;
}

static void hmac_sha256(const uint8_t *key, size_t key_len,
                        const uint8_t *msg, size_t msg_len,
                        uint8_t out[32])
{
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(info, key, key_len, msg, msg_len, out);
}

// RFC 5869 with a single 32-byte output block, which is all this protocol needs.
static void hkdf_sha256(const uint8_t *salt, size_t salt_len,
                        const uint8_t *ikm, size_t ikm_len,
                        const uint8_t *info, size_t info_len,
                        uint8_t out[32])
{
    uint8_t prk[32];
    hmac_sha256(salt, salt_len, ikm, ikm_len, prk);

    uint8_t block[64 + 1];
    size_t n = info_len > 64 ? 64 : info_len;
    memcpy(block, info, n);
    block[n] = 0x01;
    hmac_sha256(prk, sizeof(prk), block, n + 1, out);
}

void gl_derive_session_key(const uint8_t shared[GL_KEY_LEN],
                           const uint8_t salt[GL_SALT_LEN],
                           const char *setup_code,
                           const uint8_t client_id[GL_ID_LEN],
                           const uint8_t device_id[GL_ID_LEN],
                           uint8_t key[GL_KEY_LEN])
{
    uint8_t info[13 + GL_SETUP_CODE_LEN + GL_ID_LEN * 2];
    size_t n = 0;
    memcpy(info + n, "GarageLink-v1", 13); n += 13;
    memcpy(info + n, setup_code, GL_SETUP_CODE_LEN); n += GL_SETUP_CODE_LEN;
    memcpy(info + n, client_id, GL_ID_LEN); n += GL_ID_LEN;
    memcpy(info + n, device_id, GL_ID_LEN); n += GL_ID_LEN;
    hkdf_sha256(salt, GL_SALT_LEN, shared, GL_KEY_LEN, info, n, key);
}

void gl_pairing_tag(const uint8_t key[GL_KEY_LEN],
                    const uint8_t client_public[GL_PUBKEY_LEN],
                    const uint8_t device_public[GL_PUBKEY_LEN],
                    uint8_t tag[GL_TAG_LEN])
{
    uint8_t msg[6 + GL_PUBKEY_LEN * 2];
    size_t n = 0;
    memcpy(msg + n, "GLPAIR", 6); n += 6;
    memcpy(msg + n, client_public, GL_PUBKEY_LEN); n += GL_PUBKEY_LEN;
    memcpy(msg + n, device_public, GL_PUBKEY_LEN); n += GL_PUBKEY_LEN;
    uint8_t full[32];
    hmac_sha256(key, GL_KEY_LEN, msg, n, full);
    memcpy(tag, full, GL_TAG_LEN);
}

void gl_command_tag(const uint8_t key[GL_KEY_LEN], uint8_t opcode,
                    const uint8_t challenge[GL_CHALLENGE_LEN],
                    const uint8_t device_id[GL_ID_LEN],
                    const uint8_t client_id[GL_ID_LEN],
                    uint8_t tag[GL_TAG_LEN])
{
    uint8_t msg[5 + 1 + GL_CHALLENGE_LEN + GL_ID_LEN * 2];
    size_t n = 0;
    memcpy(msg + n, "GLCMD", 5); n += 5;
    msg[n++] = opcode;
    memcpy(msg + n, challenge, GL_CHALLENGE_LEN); n += GL_CHALLENGE_LEN;
    memcpy(msg + n, device_id, GL_ID_LEN); n += GL_ID_LEN;
    memcpy(msg + n, client_id, GL_ID_LEN); n += GL_ID_LEN;
    uint8_t full[32];
    hmac_sha256(key, GL_KEY_LEN, msg, n, full);
    memcpy(tag, full, GL_TAG_LEN);
}

bool gl_constant_time_equal(const uint8_t *a, const uint8_t *b, size_t len)
{
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) diff |= (uint8_t)(a[i] ^ b[i]);
    return diff == 0;
}

static uint8_t nibble(char c)
{
    if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
    return 0;
}

void gl_hex_to_bytes(const char *hex, uint8_t *out, size_t out_len)
{
    for (size_t i = 0; i < out_len; i++) {
        out[i] = (uint8_t)((nibble(hex[i * 2]) << 4) | nibble(hex[i * 2 + 1]));
    }
}

void gl_bytes_to_hex(const uint8_t *bytes, size_t len, char *out)
{
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 0x0F];
    }
    out[len * 2] = '\0';
}
