#pragma once

#include <stdbool.h>

// Checks this firmware's crypto against the vectors the iPhone app's Swift code produces.
// Returns true when every value matches. Run at boot: if it fails, pairing cannot work.
bool gl_selftest_run(void);
