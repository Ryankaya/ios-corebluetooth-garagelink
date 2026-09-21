// Host stand-in for the ESP32 hardware RNG, so the firmware's crypto and device logic can be
// compiled and tested on a Mac.
#pragma once
#include <stdlib.h>
static inline void esp_fill_random(void *buf, size_t len) { arc4random_buf(buf, len); }
