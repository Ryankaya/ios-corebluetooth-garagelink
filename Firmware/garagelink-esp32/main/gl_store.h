#pragma once

#include "gl_core.h"

// Device identity and paired phone keys survive reboots in NVS (the ESP32's flash key/value store).
void gl_store_init(void);
void gl_store_load_identity(gl_device_t *device);   // creates one on first boot
void gl_store_save_clients(const gl_device_t *device);
void gl_store_load_clients(gl_device_t *device);
