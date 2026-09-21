#pragma once

#include "gl_core.h"

// Publishes the GarageLink GATT service and starts advertising as "GL-XXXXXX".
void gl_ble_start(gl_device_t *device);

// Pushes the current door status to subscribed phones.
void gl_ble_notify_state(gl_device_t *device);
