#include "gl_hw.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "gl_hw";
static gl_device_t *s_device;

void gl_hw_pulse_button(void)
{
    // Momentary contact across the opener's wall-button terminals: exactly what pressing it does.
    gpio_set_level(GL_PIN_RELAY, 1);
    vTaskDelay(pdMS_TO_TICKS(GL_RELAY_PULSE_MS));
    gpio_set_level(GL_PIN_RELAY, 0);
    ESP_LOGI(TAG, "Relay pulsed");
}

void gl_hw_warn_before_closing(void)
{
    gpio_set_level(GL_PIN_BUZZER, 1);
    vTaskDelay(pdMS_TO_TICKS(GL_WARN_BEEP_MS));
    gpio_set_level(GL_PIN_BUZZER, 0);
}

// Polls the sensors and buttons, and runs the door state machine.
static void sensor_task(void *arg)
{
    (void)arg;
    const TickType_t period = pdMS_TO_TICKS(50);
    bool last_pair_pressed = false;
    TickType_t last_wake = xTaskGetTickCount();

    while (true) {
        bool reed_closed = gpio_get_level(GL_PIN_REED) == 0;  // switch to GND, pull-up on
        gl_device_reed_switch(s_device, reed_closed);

#if GL_PIN_OBSTRUCT >= 0
        gl_device_set_obstruction(s_device, gpio_get_level(GL_PIN_OBSTRUCT) == 0);
#endif

        bool pair_pressed = gpio_get_level(GL_PIN_PAIR_BTN) == 0;
        if (pair_pressed && !last_pair_pressed) gl_device_press_pair_button(s_device);
        last_pair_pressed = pair_pressed;

        gl_device_tick(s_device, 0.05f);
        vTaskDelayUntil(&last_wake, period);
    }
}

void gl_hw_init(gl_device_t *device)
{
    s_device = device;

    gpio_config_t outputs = {
        .pin_bit_mask = (1ULL << GL_PIN_RELAY) | (1ULL << GL_PIN_BUZZER),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&outputs));
    gpio_set_level(GL_PIN_RELAY, 0);
    gpio_set_level(GL_PIN_BUZZER, 0);

    uint64_t input_mask = (1ULL << GL_PIN_REED) | (1ULL << GL_PIN_PAIR_BTN);
#if GL_PIN_OBSTRUCT >= 0
    input_mask |= (1ULL << GL_PIN_OBSTRUCT);
#endif
    gpio_config_t inputs = {
        .pin_bit_mask = input_mask,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&inputs));

    device->pulse_button = gl_hw_pulse_button;
    device->warn_before_closing = gl_hw_warn_before_closing;

    xTaskCreate(sensor_task, "gl_sensors", 4096, NULL, 5, NULL);
}
