idf_component_register(
    SRCS "main.c" "gl_core.c" "gl_crypto.c" "gl_store.c" "gl_hw.c" "gl_ble.c" "gl_selftest.c"
    INCLUDE_DIRS "." "../.."
    REQUIRES bt nvs_flash mbedtls driver esp_timer
)
