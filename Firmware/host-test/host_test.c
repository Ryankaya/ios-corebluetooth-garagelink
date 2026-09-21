// Runs the ESP32 firmware's crypto and device logic on a Mac, with a stand-in phone, so the
// protocol can be verified before any hardware exists.
//
// Two things are proven here:
//   1. mbedTLS reproduces the exact bytes CryptoKit produces (../garagelink_vectors.h).
//   2. The device logic behaves like the Swift implementation: pairing, wrong-code lockout,
//      replay rejection and the safety interlock.
//
// Build and run: ./build.sh

#include <stdio.h>
#include <string.h>

#include "garagelink_vectors.h"
#include "gl_core.h"
#include "gl_crypto.h"

static int failures;
static int checks;
static int relay_pulses;

static void expect(bool condition, const char *what)
{
    checks++;
    if (condition) {
        printf("  ok   %s\n", what);
    } else {
        failures++;
        printf("  FAIL %s\n", what);
    }
}

static void expect_hex(const uint8_t *got, const char *expected_hex, size_t len, const char *what)
{
    uint8_t expected[GL_PUBKEY_LEN];
    gl_hex_to_bytes(expected_hex, expected, len);
    bool same = memcmp(got, expected, len) == 0;
    expect(same, what);
    if (!same) {
        char hex[GL_PUBKEY_LEN * 2 + 1];
        gl_bytes_to_hex(got, len, hex);
        printf("       expected %s\n       got      %s\n", expected_hex, hex);
    }
}

static void count_pulse(void) { relay_pulses++; }

// ---- 1. Crypto matches the iPhone app's vectors ----------------------------------------------

static void test_vectors(void)
{
    printf("Crypto vectors (must match the Swift implementation)\n");

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

    uint8_t shared_a[GL_KEY_LEN], shared_b[GL_KEY_LEN];
    expect(gl_ecdh_shared(device_private, client_public, shared_a) == 0, "ECDH from the device side");
    expect(gl_ecdh_shared(client_private, device_public, shared_b) == 0, "ECDH from the phone side");
    expect(memcmp(shared_a, shared_b, GL_KEY_LEN) == 0, "both sides agree on the shared secret");

    uint8_t key[GL_KEY_LEN];
    gl_derive_session_key(shared_a, salt, GL_VEC_SETUP_CODE, client_id, device_id, key);
    expect_hex(key, GL_VEC_SESSION_KEY, GL_KEY_LEN, "session key matches CryptoKit");

    uint8_t tag[GL_TAG_LEN];
    gl_pairing_tag(key, client_public, device_public, tag);
    expect_hex(tag, GL_VEC_PAIRING_TAG, GL_TAG_LEN, "pairing proof matches CryptoKit");

    gl_command_tag(key, GL_VEC_COMMAND_OPCODE, challenge, device_id, client_id, tag);
    expect_hex(tag, GL_VEC_COMMAND_TAG, GL_TAG_LEN, "command signature matches CryptoKit");

    uint8_t frame[GL_COMMAND_LEN];
    frame[0] = GL_VEC_COMMAND_OPCODE;
    memcpy(frame + 1, client_id, GL_ID_LEN);
    memcpy(frame + 1 + GL_ID_LEN, tag, GL_TAG_LEN);
    expect_hex(frame, GL_VEC_COMMAND_FRAME, GL_COMMAND_LEN, "full command frame matches CryptoKit");

    uint8_t wrong_key[GL_KEY_LEN];
    gl_derive_session_key(shared_a, salt, "080112", client_id, device_id, wrong_key);
    expect(memcmp(wrong_key, key, GL_KEY_LEN) != 0, "a different setup code yields a different key");
}

// ---- 2. Device logic, driven by a stand-in phone ----------------------------------------------

typedef struct {
    uint8_t client_id[GL_ID_LEN];
    uint8_t private_scalar[GL_KEY_LEN];
    uint8_t public_key[GL_PUBKEY_LEN];
    uint8_t key[GL_KEY_LEN];
} fake_phone_t;

static void phone_init(fake_phone_t *phone)
{
    memset(phone, 0, sizeof(*phone));
    gl_random_bytes(phone->client_id, GL_ID_LEN);
    gl_ecdh_generate(phone->private_scalar, phone->public_key);
}

// Returns 0 when pairing succeeded, otherwise the ATT error the device sent back.
static uint8_t phone_pair(fake_phone_t *phone, gl_device_t *device, const char *setup_code)
{
    uint8_t start[GL_PAIR_START_LEN];
    start[0] = GL_PAIR_START;
    memcpy(start + 1, phone->client_id, GL_ID_LEN);
    memcpy(start + 1 + GL_ID_LEN, phone->public_key, GL_PUBKEY_LEN);

    uint8_t reply[GL_PAIR_KEY_LEN];
    size_t reply_len = 0;
    uint8_t rc = gl_device_handle_pairing(device, start, sizeof(start), reply, &reply_len);
    if (rc != GL_ATT_OK) return rc;
    if (reply_len != GL_PAIR_KEY_LEN || reply[0] != GL_PAIR_KEY) return 0xFF;

    const uint8_t *device_public = reply + 1;
    const uint8_t *salt = reply + 1 + GL_PUBKEY_LEN;

    uint8_t shared[GL_KEY_LEN];
    if (gl_ecdh_shared(phone->private_scalar, device_public, shared) != 0) return 0xFF;
    gl_derive_session_key(shared, salt, setup_code, phone->client_id, device->device_id, phone->key);

    uint8_t confirm[GL_PAIR_CONFIRM_LEN];
    confirm[0] = GL_PAIR_CONFIRM;
    memcpy(confirm + 1, phone->client_id, GL_ID_LEN);
    gl_pairing_tag(phone->key, phone->public_key, device_public, confirm + 1 + GL_ID_LEN);

    size_t ignored = 0;
    return gl_device_handle_pairing(device, confirm, sizeof(confirm), reply, &ignored);
}

static void phone_command_frame(const fake_phone_t *phone, const gl_device_t *device,
                                uint8_t opcode, uint8_t out[GL_COMMAND_LEN])
{
    out[0] = opcode;
    memcpy(out + 1, phone->client_id, GL_ID_LEN);
    gl_command_tag(phone->key, opcode, device->challenge, device->device_id, phone->client_id,
                   out + 1 + GL_ID_LEN);
}

static void device_reset(gl_device_t *device)
{
    memset(device, 0, sizeof(*device));
    snprintf(device->name, sizeof(device->name), "Test Garage");
    snprintf(device->setup_code, sizeof(device->setup_code), "424242");
    gl_random_bytes(device->device_id, GL_ID_LEN);
    device->travel_time_s = 12.0f;
    device->pulse_button = count_pulse;
    gl_device_init(device);
    relay_pulses = 0;
}

static void test_device_logic(void)
{
    gl_device_t device;
    fake_phone_t phone;
    uint8_t frame[GL_COMMAND_LEN];

    printf("\nPairing\n");
    device_reset(&device);
    phone_init(&phone);
    expect(phone_pair(&phone, &device, device.setup_code) == GL_ATT_NOT_PAIRING_MODE,
           "refuses to pair until the PAIR button is pressed");

    gl_device_press_pair_button(&device);
    expect(phone_pair(&phone, &device, device.setup_code) == GL_ATT_OK, "pairs with the right code");
    expect(gl_device_paired_count(&device) == 1, "the phone is stored");
    expect(!gl_device_pairing_mode(&device), "pairing mode closes after success");

    printf("\nWrong setup code\n");
    device_reset(&device);
    gl_device_press_pair_button(&device);
    fake_phone_t attacker;
    uint8_t last = GL_ATT_OK;
    for (int attempt = 1; attempt <= GL_MAX_FAILED_PAIRINGS; attempt++) {
        phone_init(&attacker);
        last = phone_pair(&attacker, &device, "000000");
    }
    expect(last == GL_ATT_PAIRING_LOCKED, "locks out after repeated wrong codes");
    phone_init(&attacker);
    expect(phone_pair(&attacker, &device, device.setup_code) == GL_ATT_PAIRING_LOCKED,
           "stays locked even for the correct code");
    expect(gl_device_paired_count(&device) == 0, "no phone was paired");

    printf("\nCommands\n");
    device_reset(&device);
    gl_device_press_pair_button(&device);
    phone_init(&phone);
    expect(phone_pair(&phone, &device, device.setup_code) == GL_ATT_OK, "paired for command tests");

    phone_command_frame(&phone, &device, GL_OP_OPEN, frame);
    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_OK, "signed OPEN accepted");
    expect(device.door == GL_DOOR_OPENING, "door is opening");
    expect(relay_pulses == 1, "the relay pulsed once");

    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_UNAUTHORIZED,
           "the same frame replayed is rejected");
    expect(relay_pulses == 1, "the replay did not move the door");

    uint8_t tampered[GL_COMMAND_LEN];
    phone_command_frame(&phone, &device, GL_OP_CLOSE, tampered);
    tampered[0] = GL_OP_OPEN;  // swap the opcode, keep the signature
    expect(gl_device_handle_command(&device, tampered, sizeof(tampered)) == GL_ATT_UNAUTHORIZED,
           "a tampered opcode is rejected");

    fake_phone_t stranger;
    phone_init(&stranger);
    gl_random_bytes(stranger.key, GL_KEY_LEN);
    phone_command_frame(&stranger, &device, GL_OP_OPEN, frame);
    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_UNAUTHORIZED,
           "an unpaired phone is rejected");

    printf("\nDoor and safety\n");
    gl_device_tick(&device, device.travel_time_s + 1.0f);
    expect(device.door == GL_DOOR_OPEN, "door reaches open");

    gl_device_set_obstruction(&device, true);
    phone_command_frame(&phone, &device, GL_OP_CLOSE, frame);
    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_OBSTRUCTED,
           "refuses to close while the safety beam is blocked");

    gl_device_set_obstruction(&device, false);
    phone_command_frame(&phone, &device, GL_OP_CLOSE, frame);
    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_OK, "closes when clear");
    gl_device_tick(&device, 1.0f);
    gl_device_set_obstruction(&device, true);
    gl_device_tick(&device, 0.1f);
    expect(device.door == GL_DOOR_OPENING, "reverses when the beam breaks mid-close");

    printf("\nSensors\n");
    gl_device_reed_switch(&device, true);
    expect(device.door == GL_DOOR_CLOSED, "the reed switch overrides the estimate");
    uint8_t status[GL_STATE_LEN];
    gl_device_status(&device, status);
    expect(status[1] == 0, "position reads 0% when closed");

    phone_command_frame(&phone, &device, GL_OP_UNPAIR, frame);
    expect(gl_device_handle_command(&device, frame, sizeof(frame)) == GL_ATT_OK, "phone can unpair itself");
    expect(gl_device_paired_count(&device) == 0, "its key is gone");
}

int main(void)
{
    printf("GarageLink firmware host tests\n\n");
    test_vectors();
    test_device_logic();
    printf("\n%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
