#include "gl_core.h"

#include <string.h>

#include "esp_log.h"
#include "gl_crypto.h"

static const char *TAG = "gl_core";

static void rotate_challenge(gl_device_t *device)
{
    gl_random_bytes(device->challenge, GL_CHALLENGE_LEN);
}

void gl_device_init(gl_device_t *device)
{
    device->door = GL_DOOR_CLOSED;
    device->position = 0.0f;
    device->last_direction = GL_DOOR_CLOSING;
    if (device->travel_time_s <= 0.0f) device->travel_time_s = 12.0f;
    rotate_challenge(device);
}

size_t gl_device_info(const gl_device_t *device, uint8_t *out, size_t out_len)
{
    size_t name_len = strlen(device->name);
    if (name_len > GL_NAME_MAX) name_len = GL_NAME_MAX;
    if (out_len < GL_INFO_LEN + name_len) return 0;

    out[0] = GL_PROTOCOL_VERSION;
    out[1] = GL_FW_MAJOR;
    out[2] = GL_FW_MINOR;
    out[3] = 0;  // reserved
    memcpy(out + 4, device->device_id, GL_ID_LEN);
    memcpy(out + 4 + GL_ID_LEN, device->name, name_len);
    return GL_INFO_LEN + name_len;
}

int gl_device_paired_count(const gl_device_t *device)
{
    int count = 0;
    for (int i = 0; i < GL_MAX_CLIENTS; i++) if (device->clients[i].used) count++;
    return count;
}

bool gl_device_pairing_mode(const gl_device_t *device)
{
    return device->pairing_remaining_s > 0.0f;
}

void gl_device_status(const gl_device_t *device, uint8_t out[GL_STATE_LEN])
{
    float pct = device->position * 100.0f;
    if (pct < 0.0f) pct = 0.0f;
    if (pct > 100.0f) pct = 100.0f;
    out[0] = (uint8_t)device->door;
    out[1] = (uint8_t)(pct + 0.5f);
    out[2] = (uint8_t)((gl_device_pairing_mode(device) ? 0x01 : 0x00) |
                       (device->obstructed ? 0x02 : 0x00));
    out[3] = (uint8_t)gl_device_paired_count(device);
}

static void notify_state(gl_device_t *device)
{
    if (device->on_state_changed) device->on_state_changed(device);
}

// A real opener has one input: the wall button. Open/close/stop all become a single pulse,
// and the state machine tracks what that pulse means from where the door currently is.
static void pulse(gl_device_t *device)
{
    if (device->pulse_button) device->pulse_button();
}

static void start_opening(gl_device_t *device)
{
    if (device->door == GL_DOOR_OPEN || device->door == GL_DOOR_OPENING) return;
    pulse(device);
    device->door = GL_DOOR_OPENING;
    device->last_direction = GL_DOOR_OPENING;
    notify_state(device);
}

static void start_closing(gl_device_t *device)
{
    if (device->door == GL_DOOR_CLOSED || device->door == GL_DOOR_CLOSING) return;
    if (device->warn_before_closing) device->warn_before_closing();
    pulse(device);
    device->door = GL_DOOR_CLOSING;
    device->last_direction = GL_DOOR_CLOSING;
    notify_state(device);
}

static void stop_door(gl_device_t *device)
{
    if (device->door != GL_DOOR_OPENING && device->door != GL_DOOR_CLOSING) return;
    pulse(device);
    device->door = GL_DOOR_STOPPED;
    notify_state(device);
}

static bool toggle_would_close(const gl_device_t *device)
{
    return device->door == GL_DOOR_OPEN ||
           (device->door == GL_DOOR_STOPPED && device->last_direction == GL_DOOR_OPENING);
}

static void toggle(gl_device_t *device)
{
    switch (device->door) {
    case GL_DOOR_CLOSED: start_opening(device); break;
    case GL_DOOR_OPEN: start_closing(device); break;
    case GL_DOOR_OPENING:
    case GL_DOOR_CLOSING: stop_door(device); break;
    case GL_DOOR_STOPPED:
        if (device->last_direction == GL_DOOR_OPENING) start_closing(device);
        else start_opening(device);
        break;
    }
}

void gl_device_press_wall_button(gl_device_t *device) { toggle(device); }

void gl_device_press_pair_button(gl_device_t *device)
{
    device->pairing_remaining_s = (float)GL_PAIRING_WINDOW_S;
    device->failed_pairings = 0;  // clearing the lockout needs physical access
    ESP_LOGI(TAG, "Pairing mode on for %d s (setup code %s)", GL_PAIRING_WINDOW_S, device->setup_code);
    notify_state(device);
}

void gl_device_set_obstruction(gl_device_t *device, bool blocked)
{
    if (device->obstructed == blocked) return;
    device->obstructed = blocked;
    ESP_LOGI(TAG, "Safety sensor %s", blocked ? "BLOCKED" : "clear");
    notify_state(device);
}

// The reed switch is ground truth for "closed"; the timer only estimates everything else.
void gl_device_reed_switch(gl_device_t *device, bool door_closed)
{
    if (door_closed) {
        if (device->door != GL_DOOR_CLOSED || device->position != 0.0f) {
            device->door = GL_DOOR_CLOSED;
            device->position = 0.0f;
            notify_state(device);
        }
    } else if (device->door == GL_DOOR_CLOSED) {
        // Moved by the wall button or a remote we don't control.
        device->door = GL_DOOR_OPENING;
        device->last_direction = GL_DOOR_OPENING;
        notify_state(device);
    }
}

void gl_device_forget_all(gl_device_t *device)
{
    memset(device->clients, 0, sizeof(device->clients));
    memset(device->pending, 0, sizeof(device->pending));
    if (device->on_clients_changed) device->on_clients_changed(device);
    notify_state(device);
}

bool gl_device_tick(gl_device_t *device, float dt)
{
    uint8_t before[GL_STATE_LEN];
    gl_device_status(device, before);

    if (device->pairing_remaining_s > 0.0f) {
        device->pairing_remaining_s -= dt;
        if (device->pairing_remaining_s <= 0.0f) {
            device->pairing_remaining_s = 0.0f;
            memset(device->pending, 0, sizeof(device->pending));
            ESP_LOGI(TAG, "Pairing mode timed out");
        }
    }

    float step = dt / device->travel_time_s;
    switch (device->door) {
    case GL_DOOR_OPENING:
        device->position += step;
        if (device->position >= 1.0f) {
            device->position = 1.0f;
            device->door = GL_DOOR_OPEN;
        }
        break;
    case GL_DOOR_CLOSING:
        if (device->obstructed) {
            // The opener reverses on its own; follow it so the app shows the truth.
            device->door = GL_DOOR_OPENING;
            device->last_direction = GL_DOOR_OPENING;
            ESP_LOGW(TAG, "Obstruction while closing - door reversing");
        } else {
            device->position -= step;
            if (device->position <= 0.0f) {
                device->position = 0.0f;
                device->door = GL_DOOR_CLOSED;
            }
        }
        break;
    default:
        break;
    }

    uint8_t after[GL_STATE_LEN];
    gl_device_status(device, after);
    bool changed = memcmp(before, after, GL_STATE_LEN) != 0;
    if (changed) notify_state(device);
    return changed;
}

static gl_paired_client_t *find_client(gl_device_t *device, const uint8_t client_id[GL_ID_LEN])
{
    for (int i = 0; i < GL_MAX_CLIENTS; i++) {
        if (device->clients[i].used && memcmp(device->clients[i].client_id, client_id, GL_ID_LEN) == 0) {
            return &device->clients[i];
        }
    }
    return NULL;
}

uint8_t gl_device_handle_command(gl_device_t *device, const uint8_t *data, size_t len)
{
    uint8_t challenge[GL_CHALLENGE_LEN];
    memcpy(challenge, device->challenge, GL_CHALLENGE_LEN);
    rotate_challenge(device);  // every attempt burns it, valid or not

    if (len != GL_COMMAND_LEN) return GL_ATT_INVALID_LENGTH;

    uint8_t opcode = data[0];
    const uint8_t *client_id = data + 1;
    const uint8_t *tag = data + 1 + GL_ID_LEN;

    gl_paired_client_t *client = find_client(device, client_id);
    if (!client) {
        ESP_LOGW(TAG, "Command from an unpaired phone");
        return GL_ATT_UNAUTHORIZED;
    }

    uint8_t expected[GL_TAG_LEN];
    gl_command_tag(client->key, opcode, challenge, device->device_id, client_id, expected);
    if (!gl_constant_time_equal(expected, tag, GL_TAG_LEN)) {
        ESP_LOGW(TAG, "Command rejected: bad signature (replayed or tampered)");
        return GL_ATT_UNAUTHORIZED;
    }

    switch (opcode) {
    case GL_OP_OPEN:
        start_opening(device);
        break;
    case GL_OP_CLOSE:
        if (device->obstructed) return GL_ATT_OBSTRUCTED;
        start_closing(device);
        break;
    case GL_OP_STOP:
        stop_door(device);
        break;
    case GL_OP_TOGGLE:
        if (toggle_would_close(device) && device->obstructed) return GL_ATT_OBSTRUCTED;
        toggle(device);
        break;
    case GL_OP_UNPAIR:
        memset(client, 0, sizeof(*client));
        if (device->on_clients_changed) device->on_clients_changed(device);
        notify_state(device);
        ESP_LOGI(TAG, "A phone unpaired itself");
        break;
    default:
        return GL_ATT_UNSUPPORTED_OP;
    }
    return GL_ATT_OK;
}

uint8_t gl_device_handle_pairing(gl_device_t *device, const uint8_t *data, size_t len,
                                 uint8_t *reply, size_t *reply_len)
{
    *reply_len = 0;
    if (len < 1) return GL_ATT_MALFORMED;

    switch (data[0]) {
    case GL_PAIR_START: {
        if (len != GL_PAIR_START_LEN) return GL_ATT_INVALID_LENGTH;
        if (device->failed_pairings >= GL_MAX_FAILED_PAIRINGS) return GL_ATT_PAIRING_LOCKED;
        if (!gl_device_pairing_mode(device)) return GL_ATT_NOT_PAIRING_MODE;

        const uint8_t *client_id = data + 1;
        const uint8_t *client_public = data + 1 + GL_ID_LEN;
        if (!gl_public_key_is_valid(client_public)) return GL_ATT_MALFORMED;

        gl_pending_pairing_t *slot = NULL;
        for (int i = 0; i < GL_MAX_PENDING; i++) {
            if (!device->pending[i].used ||
                memcmp(device->pending[i].client_id, client_id, GL_ID_LEN) == 0) {
                slot = &device->pending[i];
                break;
            }
        }
        if (!slot) slot = &device->pending[0];  // oldest gets replaced

        memset(slot, 0, sizeof(*slot));
        if (gl_ecdh_generate(slot->private_scalar, slot->device_public) != 0) return GL_ATT_MALFORMED;
        memcpy(slot->client_id, client_id, GL_ID_LEN);
        memcpy(slot->client_public, client_public, GL_PUBKEY_LEN);
        gl_random_bytes(slot->salt, GL_SALT_LEN);
        slot->used = true;

        reply[0] = GL_PAIR_KEY;
        memcpy(reply + 1, slot->device_public, GL_PUBKEY_LEN);
        memcpy(reply + 1 + GL_PUBKEY_LEN, slot->salt, GL_SALT_LEN);
        *reply_len = GL_PAIR_KEY_LEN;
        ESP_LOGI(TAG, "Pairing started by a phone");
        return GL_ATT_OK;
    }

    case GL_PAIR_CONFIRM: {
        if (len != GL_PAIR_CONFIRM_LEN) return GL_ATT_INVALID_LENGTH;
        const uint8_t *client_id = data + 1;
        const uint8_t *tag = data + 1 + GL_ID_LEN;

        gl_pending_pairing_t *slot = NULL;
        for (int i = 0; i < GL_MAX_PENDING; i++) {
            if (device->pending[i].used &&
                memcmp(device->pending[i].client_id, client_id, GL_ID_LEN) == 0) {
                slot = &device->pending[i];
                break;
            }
        }
        if (!slot) return GL_ATT_NO_PAIR_SESSION;
        if (!gl_device_pairing_mode(device)) return GL_ATT_NOT_PAIRING_MODE;

        uint8_t shared[GL_KEY_LEN], key[GL_KEY_LEN], expected[GL_TAG_LEN];
        if (gl_ecdh_shared(slot->private_scalar, slot->client_public, shared) != 0) {
            memset(slot, 0, sizeof(*slot));
            return GL_ATT_MALFORMED;
        }
        gl_derive_session_key(shared, slot->salt, device->setup_code, client_id, device->device_id, key);
        gl_pairing_tag(key, slot->client_public, slot->device_public, expected);

        if (!gl_constant_time_equal(expected, tag, GL_TAG_LEN)) {
            memset(slot, 0, sizeof(*slot));
            device->failed_pairings++;
            if (device->failed_pairings >= GL_MAX_FAILED_PAIRINGS) {
                device->pairing_remaining_s = 0.0f;
                memset(device->pending, 0, sizeof(device->pending));
                ESP_LOGW(TAG, "Wrong setup code - pairing locked until PAIR is pressed");
                notify_state(device);
                return GL_ATT_PAIRING_LOCKED;
            }
            ESP_LOGW(TAG, "Wrong setup code (%d/%d)", device->failed_pairings, GL_MAX_FAILED_PAIRINGS);
            return GL_ATT_BAD_SETUP_CODE;
        }

        gl_paired_client_t *client = find_client(device, client_id);
        if (!client) {
            for (int i = 0; i < GL_MAX_CLIENTS; i++) {
                if (!device->clients[i].used) { client = &device->clients[i]; break; }
            }
        }
        if (!client) return GL_ATT_MALFORMED;  // client list full

        memcpy(client->client_id, client_id, GL_ID_LEN);
        memcpy(client->key, key, GL_KEY_LEN);
        client->used = true;

        memset(device->pending, 0, sizeof(device->pending));
        device->failed_pairings = 0;
        device->pairing_remaining_s = 0.0f;
        if (device->on_clients_changed) device->on_clients_changed(device);
        notify_state(device);
        ESP_LOGI(TAG, "Paired a phone (%d total)", gl_device_paired_count(device));
        return GL_ATT_OK;
    }

    default:
        return GL_ATT_UNSUPPORTED_OP;
    }
}
