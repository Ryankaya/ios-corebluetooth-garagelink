#!/bin/bash
# Builds and runs the firmware's protocol logic on this computer, using the copy of mbedTLS that
# ships inside ESP-IDF. No ESP32 required.
#
#   MBEDTLS_BUILD=/path/to/mbedtls-build ./build.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
idf="${IDF_PATH:-$HOME/esp/esp-idf}"
mbedtls_src="$idf/components/mbedtls/mbedtls"
mbedtls_build="${MBEDTLS_BUILD:-$here/.mbedtls-build}"

if [ ! -f "$mbedtls_build/library/libmbedcrypto.a" ]; then
  echo "Building mbedTLS for this machine (one time)…"
  cmake -S "$mbedtls_src" -B "$mbedtls_build" -DENABLE_TESTING=Off -DENABLE_PROGRAMS=Off -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$mbedtls_build" --target mbedcrypto -j 8 >/dev/null
fi

cc -std=c11 -Wall -Wextra -O1 \
  -I "$here/shims" -I "$here/../garagelink-esp32/main" -I "$here/.." -I "$mbedtls_src/include" \
  "$here/host_test.c" "$here/../garagelink-esp32/main/gl_crypto.c" "$here/../garagelink-esp32/main/gl_core.c" \
  -L "$mbedtls_build/library" -lmbedcrypto \
  -o "$here/host_test"

"$here/host_test"
