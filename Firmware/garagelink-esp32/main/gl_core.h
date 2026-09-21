#pragma once

#include "gl_protocol.h"

typedef struct {
    uint8_t client_id[GL_ID_LEN];
    uint8_t key[GL_KEY_LEN];
    bool used;
} gl_paired_client_t;

typedef struct {
    uint8_t client_id[GL_ID_LEN];
    uint8_t private_scalar[GL_KEY_LEN];
    uint8_t device_public[GL_PUBKEY_LEN];
    uint8_t client_public[GL_PUBKEY_LEN];
    uint8_t salt[GL_SALT_LEN];
    bool used;
} gl_pending_pairing_t;

typedef struct gl_device gl_device_t;

struct gl_device {
    uint8_t device_id[GL_ID_LEN];
    char setup_code[GL_SETUP_CODE_LEN + 1];
    char name[GL_NAME_MAX + 1];

    gl_door_state_t door;
    float position;          // 0 = closed, 1 = open
    float travel_time_s;     // how long a full open or close takes
    bool obstructed;
    gl_door_state_t last_direction;

    uint8_t challenge[GL_CHALLENGE_LEN];
    float pairing_remaining_s;
    int failed_pairings;

    gl_paired_client_t clients[GL_MAX_CLIENTS];
    gl_pending_pairing_t pending[GL_MAX_PENDING];

    // Hardware hooks, so the protocol logic stays testable and hardware-free.
    void (*pulse_button)(void);            // closes the relay briefly: one wall-button press
    void (*warn_before_closing)(void);     // beeper/light before a remote close
    void (*on_state_changed)(gl_device_t *device);
    void (*on_clients_changed)(gl_device_t *device);
};

void gl_device_init(gl_device_t *device);

size_t gl_device_info(const gl_device_t *device, uint8_t *out, size_t out_len);
void gl_device_status(const gl_device_t *device, uint8_t out[GL_STATE_LEN]);
int gl_device_paired_count(const gl_device_t *device);
bool gl_device_pairing_mode(const gl_device_t *device);

// Return 0 on success, otherwise an ATT error code to send back on the write response.
uint8_t gl_device_handle_command(gl_device_t *device, const uint8_t *data, size_t len);
uint8_t gl_device_handle_pairing(gl_device_t *device, const uint8_t *data, size_t len,
                                 uint8_t *reply, size_t *reply_len);

// Physical controls and sensors.
void gl_device_press_pair_button(gl_device_t *device);
void gl_device_press_wall_button(gl_device_t *device);
void gl_device_set_obstruction(gl_device_t *device, bool blocked);
void gl_device_reed_switch(gl_device_t *device, bool door_closed);
void gl_device_forget_all(gl_device_t *device);

// Advances the door simulation between sensor readings. True when the status bytes changed.
bool gl_device_tick(gl_device_t *device, float dt);
