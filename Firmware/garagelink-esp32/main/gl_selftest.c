#include "gl_selftest.h"

#include <stdbool.h>
#include <string.h>

#include "esp_log.h"
#include "garagelink_vectors.h"
#include "gl_crypto.h"

static const char *TAG = "gl_selftest";

static bool check(const char *what, const uint8_t *got, const char *expected_hex, size_t len)
{
    uint8_t expected[GL_PUBKEY_LEN];
    gl_hex_to_bytes(expected_hex, expected, len);
    if (memcmp(got, expected, len) == 0) return true;

    char got_hex[GL_PUBKEY_LEN * 2 + 1];
    gl_bytes_to_hex(got, len, got_hex);
    ESP_LOGE(TAG, "%s mismatch\n  expected %s\n  got      %s", what, expected_hex, got_hex);
    return false;
}

bool gl_selftest_run(void)
{
    uint8_t device_private[GL_KEY_LEN], client_private[GL_KEY_LEN];
    uint8_t device_public[GL_PUBKEY_LEN], client_public[GL_PUBKEY_LEN];
    uint8_t salt[GL_SALT_LEN], challenge[GL_CHALLENGE_LEN];
    uint8_t device_id[GL_ID_LEN], client_id[GL_ID_LEN];

    gl_hex_to_bytes(GL_VEC_DEVICE_PRIVATE, device_private, GL_KEY_LEN);
    gl_hex_to_bytes(GL_VEC_CLIENT_PRIVATE, client_private, GL_KEY_LEN);
    gl_hex_to_bytes(GL_VEC_DEVICE_PUBLIC, device_public, GL_PUBKEY_LEN);
    gl_hex_to_bytes(GL_VEC_CLIENT_PUBLIC, client_public, GL_PUBKEY_LEN);
    gl_hex_to_bytes(GL_VEC_SALT, salt, GL_SALT_LEN);
    gl_hex_to_bytes(GL_VEC_CHALLENGE, challenge, GL_CHALLENGE_LEN);
    gl_hex_to_bytes(GL_VEC_DEVICE_ID, device_id, GL_ID_LEN);
    gl_hex_to_bytes(GL_VEC_CLIENT_ID, client_id, GL_ID_LEN);

    bool ok = true;

    // Same key from either side of the exchange.
    uint8_t shared_a[GL_KEY_LEN], shared_b[GL_KEY_LEN];
    if (gl_ecdh_shared(device_private, client_public, shared_a) != 0 ||
        gl_ecdh_shared(client_private, device_public, shared_b) != 0) {
        ESP_LOGE(TAG, "ECDH failed");
        return false;
    }
    if (memcmp(shared_a, shared_b, GL_KEY_LEN) != 0) {
        ESP_LOGE(TAG, "ECDH halves disagree");
        ok = false;
    }

    uint8_t key[GL_KEY_LEN];
    gl_derive_session_key(shared_a, salt, GL_VEC_SETUP_CODE, client_id, device_id, key);
    ok &= check("session key", key, GL_VEC_SESSION_KEY, GL_KEY_LEN);

    uint8_t tag[GL_TAG_LEN];
    gl_pairing_tag(key, client_public, device_public, tag);
    ok &= check("pairing tag", tag, GL_VEC_PAIRING_TAG, GL_TAG_LEN);

    gl_command_tag(key, GL_VEC_COMMAND_OPCODE, challenge, device_id, client_id, tag);
    ok &= check("command tag", tag, GL_VEC_COMMAND_TAG, GL_TAG_LEN);

    if (ok) ESP_LOGI(TAG, "Crypto matches the iPhone app's test vectors");
    return ok;
}
