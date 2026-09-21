#include "gl_store.h"

#include <string.h>

#include "esp_log.h"
#include "gl_crypto.h"
#include "nvs.h"
#include "nvs_flash.h"

static const char *TAG = "gl_store";
static const char *NAMESPACE = "garagelink";

void gl_store_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

void gl_store_load_identity(gl_device_t *device)
{
    nvs_handle_t handle;
    ESP_ERROR_CHECK(nvs_open(NAMESPACE, NVS_READWRITE, &handle));

    size_t len = GL_ID_LEN;
    if (nvs_get_blob(handle, "device_id", device->device_id, &len) != ESP_OK || len != GL_ID_LEN) {
        // First boot: mint an identity and a setup code, like a unit coming off the line.
        gl_random_bytes(device->device_id, GL_ID_LEN);
        uint32_t code = 0;
        gl_random_bytes((uint8_t *)&code, sizeof(code));
        snprintf(device->setup_code, sizeof(device->setup_code), "%06u", (unsigned)(code % 1000000u));
        ESP_ERROR_CHECK(nvs_set_blob(handle, "device_id", device->device_id, GL_ID_LEN));
        ESP_ERROR_CHECK(nvs_set_str(handle, "setup_code", device->setup_code));
        ESP_ERROR_CHECK(nvs_commit(handle));
        ESP_LOGI(TAG, "New device identity created");
    } else {
        size_t code_len = sizeof(device->setup_code);
        if (nvs_get_str(handle, "setup_code", device->setup_code, &code_len) != ESP_OK) {
            snprintf(device->setup_code, sizeof(device->setup_code), "000000");
        }
    }
    nvs_close(handle);
}

void gl_store_save_clients(const gl_device_t *device)
{
    nvs_handle_t handle;
    ESP_ERROR_CHECK(nvs_open(NAMESPACE, NVS_READWRITE, &handle));
    ESP_ERROR_CHECK(nvs_set_blob(handle, "clients", device->clients, sizeof(device->clients)));
    ESP_ERROR_CHECK(nvs_commit(handle));
    nvs_close(handle);
}

void gl_store_load_clients(gl_device_t *device)
{
    nvs_handle_t handle;
    if (nvs_open(NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) return;
    size_t len = sizeof(device->clients);
    if (nvs_get_blob(handle, "clients", device->clients, &len) != ESP_OK || len != sizeof(device->clients)) {
        memset(device->clients, 0, sizeof(device->clients));
    }
    nvs_close(handle);
}
