#pragma once

#include "gl_core.h"

// Pin map. Change these to match your wiring; every one is a plain GPIO.
#define GL_PIN_RELAY      5   // -> opto-isolated relay module IN (relay contacts across the wall button)
#define GL_PIN_REED      18   // -> reed switch, other leg to GND (closed = door shut)
#define GL_PIN_BUZZER     6   // -> active buzzer (warns before a remote close)
#define GL_PIN_PAIR_BTN   0   // BOOT button on most dev boards
#define GL_PIN_OBSTRUCT  -1   // optional safety-beam input; -1 = not fitted

#define GL_RELAY_PULSE_MS  300   // how long the "button" is held
#define GL_WARN_BEEP_MS   3000   // warning before closing, as commercial openers do

void gl_hw_init(gl_device_t *device);
void gl_hw_pulse_button(void);
void gl_hw_warn_before_closing(void);
