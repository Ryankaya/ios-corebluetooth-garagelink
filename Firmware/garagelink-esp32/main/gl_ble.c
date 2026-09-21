#include "gl_ble.h"

#include <string.h>

#include "esp_log.h"
#include "gl_crypto.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "gl_ble";

static gl_device_t *s_device;
static uint8_t s_addr_type;
static char s_name[16];
static uint16_t s_state_handle;
static uint16_t s_pair_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_pair_reply_conn = BLE_HS_CONN_HANDLE_NONE;
static uint8_t s_pair_reply[GL_PAIR_KEY_LEN];
static size_t s_pair_reply_len;

static void start_advertising(void);

// NimBLE wants UUIDs little-endian; the protocol writes them big-endian like every other tool.
static void uuid_from_string(const char *text, ble_uuid128_t *out)
{
    uint8_t bytes[16];
    size_t n = 0;
    for (const char *p = text; *p && n < 16; p++) {
        if (*p == '-') continue;
        char pair[3] = { p[0], p[1], 0 };
        gl_hex_to_bytes(pair, &bytes[n++], 1);
        p++;
    }
    out->u.type = BLE_UUID_TYPE_128;
    for (int i = 0; i < 16; i++) out->value[i] = bytes[15 - i];
}

static ble_uuid128_t s_uuid_service, s_uuid_info, s_uuid_state, s_uuid_challenge, s_uuid_command, s_uuid_pairing;

static int access_cb(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)arg;
    const ble_uuid_t *uuid = ctxt->chr->uuid;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        uint8_t buffer[GL_INFO_LEN + GL_NAME_MAX];
        size_t len = 0;
        if (ble_uuid_cmp(uuid, &s_uuid_info.u) == 0) {
            len = gl_device_info(s_device, buffer, sizeof(buffer));
        } else if (ble_uuid_cmp(uuid, &s_uuid_state.u) == 0) {
            gl_device_status(s_device, buffer);
            len = GL_STATE_LEN;
        } else if (ble_uuid_cmp(uuid, &s_uuid_challenge.u) == 0) {
            memcpy(buffer, s_device->challenge, GL_CHALLENGE_LEN);
            len = GL_CHALLENGE_LEN;
        } else {
            return BLE_ATT_ERR_READ_NOT_PERMITTED;
        }
        return os_mbuf_append(ctxt->om, buffer, len) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint8_t data[GL_PAIR_START_LEN];
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len > sizeof(data)) return GL_ATT_INVALID_LENGTH;
        if (ble_hs_mbuf_to_flat(ctxt->om, data, sizeof(data), &len) != 0) return GL_ATT_MALFORMED;

        if (ble_uuid_cmp(uuid, &s_uuid_command.u) == 0) {
            // Returning a non-zero value here sends it back as the ATT error code, which is how
            // the phone learns "wrong signature" or "safety beam blocked".
            return gl_device_handle_command(s_device, data, len);
        }
        if (ble_uuid_cmp(uuid, &s_uuid_pairing.u) == 0) {
            size_t reply_len = 0;
            uint8_t reply[GL_PAIR_KEY_LEN];
            uint8_t rc = gl_device_handle_pairing(s_device, data, len, reply, &reply_len);
            if (rc == GL_ATT_OK && reply_len > 0) {
                // Notify after the write response, matching the app's expectation.
                memcpy(s_pair_reply, reply, reply_len);
                s_pair_reply_len = reply_len;
                s_pair_reply_conn = conn_handle;
            }
            return rc;
        }
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    return BLE_ATT_ERR_UNLIKELY;
}

static struct ble_gatt_chr_def s_characteristics[6];
static struct ble_gatt_svc_def s_services[2];

static void build_service(void)
{
    uuid_from_string(GL_SERVICE_UUID, &s_uuid_service);
    uuid_from_string(GL_CHR_INFO_UUID, &s_uuid_info);
    uuid_from_string(GL_CHR_STATE_UUID, &s_uuid_state);
    uuid_from_string(GL_CHR_CHAL_UUID, &s_uuid_challenge);
    uuid_from_string(GL_CHR_CMD_UUID, &s_uuid_command);
    uuid_from_string(GL_CHR_PAIR_UUID, &s_uuid_pairing);

    s_characteristics[0] = (struct ble_gatt_chr_def){
        .uuid = &s_uuid_info.u, .access_cb = access_cb, .flags = BLE_GATT_CHR_F_READ };
    s_characteristics[1] = (struct ble_gatt_chr_def){
        .uuid = &s_uuid_state.u, .access_cb = access_cb, .val_handle = &s_state_handle,
        .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY };
    s_characteristics[2] = (struct ble_gatt_chr_def){
        .uuid = &s_uuid_challenge.u, .access_cb = access_cb, .flags = BLE_GATT_CHR_F_READ };
    s_characteristics[3] = (struct ble_gatt_chr_def){
        .uuid = &s_uuid_command.u, .access_cb = access_cb, .flags = BLE_GATT_CHR_F_WRITE };
    s_characteristics[4] = (struct ble_gatt_chr_def){
        .uuid = &s_uuid_pairing.u, .access_cb = access_cb, .val_handle = &s_pair_handle,
        .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY };
    s_characteristics[5] = (struct ble_gatt_chr_def){ 0 };

    s_services[0] = (struct ble_gatt_svc_def){
        .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &s_uuid_service.u, .characteristics = s_characteristics };
    s_services[1] = (struct ble_gatt_svc_def){ 0 };
}

void gl_ble_notify_state(gl_device_t *device)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    uint8_t status[GL_STATE_LEN];
    gl_device_status(device, status);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(status, sizeof(status));
    if (om) ble_gatts_notify_custom(s_conn_handle, s_state_handle, om);
}

static void send_pending_pairing_reply(void)
{
    if (s_pair_reply_conn == BLE_HS_CONN_HANDLE_NONE || s_pair_reply_len == 0) return;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(s_pair_reply, s_pair_reply_len);
    if (om) ble_gatts_notify_custom(s_pair_reply_conn, s_pair_handle, om);
    s_pair_reply_len = 0;
    s_pair_reply_conn = BLE_HS_CONN_HANDLE_NONE;
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            ESP_LOGI(TAG, "Phone connected");
        } else {
            start_advertising();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Phone disconnected (reason 0x%02x)", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_pair_reply_conn = BLE_HS_CONN_HANDLE_NONE;
        start_advertising();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "Subscribed to handle %d", event->subscribe.attr_handle);
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        start_advertising();
        break;
    default:
        break;
    }
    return 0;
}

static void start_advertising(void)
{
    // The 128-bit service UUID fills the advertisement, so the name goes in the scan response.
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &s_uuid_service;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) ESP_LOGE(TAG, "adv_set_fields failed: %d", rc);

    struct ble_hs_adv_fields scan_response = { 0 };
    scan_response.name = (uint8_t *)s_name;
    scan_response.name_len = strlen(s_name);
    scan_response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&scan_response);
    if (rc != 0) ESP_LOGE(TAG, "adv_rsp_set_fields failed: %d", rc);

    struct ble_gap_adv_params params = { 0 };
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0) ESP_LOGE(TAG, "adv_start failed: %d", rc);
    else ESP_LOGI(TAG, "Advertising as %s", s_name);
}

static void on_sync(void)
{
    ESP_ERROR_CHECK(ble_hs_util_ensure_addr(0));
    ESP_ERROR_CHECK(ble_hs_id_infer_auto(0, &s_addr_type));
    start_advertising();
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE reset, reason %d", reason);
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// Notifications must be sent from the NimBLE host task, not from the sensor task.
static void notify_task(void *arg)
{
    (void)arg;
    uint8_t last[GL_STATE_LEN] = { 0xFF, 0xFF, 0xFF, 0xFF };
    while (true) {
        send_pending_pairing_reply();
        uint8_t now[GL_STATE_LEN];
        gl_device_status(s_device, now);
        if (memcmp(now, last, GL_STATE_LEN) != 0) {
            memcpy(last, now, GL_STATE_LEN);
            gl_ble_notify_state(s_device);
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

void gl_ble_start(gl_device_t *device)
{
    s_device = device;
    snprintf(s_name, sizeof(s_name), "GL-%02X%02X%02X",
             device->device_id[0], device->device_id[1], device->device_id[2]);

    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    build_service();
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(s_services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(s_services));
    ESP_ERROR_CHECK(ble_svc_gap_device_name_set(s_name));

    nimble_port_freertos_init(host_task);
    xTaskCreate(notify_task, "gl_notify", 4096, NULL, 4, NULL);
}
