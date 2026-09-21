// GarageLink garage door controller — ESP32 firmware.
//
// Speaks the same Bluetooth LE protocol as the GarageLink iPhone app and the macOS simulator:
// ECDH pairing bound to the printed setup code, HMAC-signed commands over a one-time challenge.
// The relay pulses the opener's wall-button terminals; a reed switch reports the real door state.
//
// HomeKit is deliberately not here yet. It will sit beside this file talking to the same
// gl_device_t, so the Home app and this protocol drive one device.

#include <stdio.h>

#include "esp_log.h"
#include "gl_ble.h"
#include "gl_core.h"
#include "gl_hw.h"
#include "gl_selftest.h"
#include "gl_store.h"

static const char *TAG = "garagelink";
static gl_device_t s_device;

static void clients_changed(gl_device_t *device)
{
    gl_store_save_clients(device);
}

void app_main(void)
{
    gl_store_init();

    snprintf(s_device.name, sizeof(s_device.name), "Garage");
    s_device.travel_time_s = 12.0f;
    gl_store_load_identity(&s_device);
    gl_store_load_clients(&s_device);
    gl_device_init(&s_device);
    s_device.on_clients_changed = clients_changed;

    if (!gl_selftest_run()) {
        ESP_LOGE(TAG, "Crypto self-test FAILED - pairing with the app will not work");
    }

    gl_hw_init(&s_device);
    gl_ble_start(&s_device);

    ESP_LOGI(TAG, "GL-%02X%02X%02X ready | setup code %s | paired phones %d",
             s_device.device_id[0], s_device.device_id[1], s_device.device_id[2],
             s_device.setup_code, gl_device_paired_count(&s_device));

    if (gl_device_paired_count(&s_device) == 0) {
        gl_device_press_pair_button(&s_device);  // first boot: ready to pair
    }
}
