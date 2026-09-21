// GarageLink protocol v1 — device side.
//
// Same wire format as Packages/GarageKit/Sources/GarageProtocol (the iPhone app's Swift code).
// Anything changed here must change there too; the shared test vectors in ../garagelink_vectors.h
// exist to catch drift.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define GL_PROTOCOL_VERSION 1
#define GL_FW_MAJOR 1
#define GL_FW_MINOR 0

#define GL_SERVICE_UUID    "6E4A1000-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
#define GL_CHR_INFO_UUID   "6E4A1001-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
#define GL_CHR_STATE_UUID  "6E4A1002-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
#define GL_CHR_CHAL_UUID   "6E4A1003-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
#define GL_CHR_CMD_UUID    "6E4A1004-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
#define GL_CHR_PAIR_UUID   "6E4A1005-8B1C-4F6E-9D2A-3C0FFEE0B1E5"

#define GL_ID_LEN        8
#define GL_KEY_LEN       32
#define GL_TAG_LEN       16
#define GL_SALT_LEN      16
#define GL_CHALLENGE_LEN 16
#define GL_PUBKEY_LEN    65
#define GL_SETUP_CODE_LEN 6
#define GL_NAME_MAX      20

#define GL_INFO_LEN      (4 + GL_ID_LEN)               // + name bytes
#define GL_STATE_LEN     4
#define GL_COMMAND_LEN   (1 + GL_ID_LEN + GL_TAG_LEN)  // 25
#define GL_PAIR_START_LEN   (1 + GL_ID_LEN + GL_PUBKEY_LEN)  // 74
#define GL_PAIR_KEY_LEN     (1 + GL_PUBKEY_LEN + GL_SALT_LEN) // 82
#define GL_PAIR_CONFIRM_LEN (1 + GL_ID_LEN + GL_TAG_LEN)      // 25

// Opcodes written to the Command characteristic.
enum {
    GL_OP_OPEN   = 0x01,
    GL_OP_CLOSE  = 0x02,
    GL_OP_STOP   = 0x03,
    GL_OP_TOGGLE = 0x04,
    GL_OP_UNPAIR = 0x10,
};

// Pairing frame kinds.
enum {
    GL_PAIR_START   = 0x01,
    GL_PAIR_KEY     = 0x02,
    GL_PAIR_CONFIRM = 0x03,
};

// ATT error codes returned on writes. 0x80+ is the application range; 0x05 and 0x0F are avoided
// because iOS answers those by starting OS-level bonding.
enum {
    GL_ATT_OK                = 0x00,
    GL_ATT_INVALID_LENGTH    = 0x0D,
    GL_ATT_UNAUTHORIZED      = 0x80,
    GL_ATT_NOT_PAIRING_MODE  = 0x81,
    GL_ATT_BAD_SETUP_CODE    = 0x82,
    GL_ATT_PAIRING_LOCKED    = 0x83,
    GL_ATT_NO_PAIR_SESSION   = 0x84,
    GL_ATT_OBSTRUCTED        = 0x85,
    GL_ATT_UNSUPPORTED_OP    = 0x86,
    GL_ATT_MALFORMED         = 0x87,
};

typedef enum {
    GL_DOOR_CLOSED = 0,
    GL_DOOR_OPENING = 1,
    GL_DOOR_OPEN = 2,
    GL_DOOR_CLOSING = 3,
    GL_DOOR_STOPPED = 4,
} gl_door_state_t;

#define GL_MAX_CLIENTS 8
#define GL_MAX_PENDING 2
#define GL_MAX_FAILED_PAIRINGS 5
#define GL_PAIRING_WINDOW_S 120
