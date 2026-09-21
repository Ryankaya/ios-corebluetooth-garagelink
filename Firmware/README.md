# GarageLink firmware (ESP32)

Turns an ESP32 into the garage door controller the iPhone app talks to. Same Bluetooth protocol as
the macOS simulator: ECDH pairing bound to the printed setup code, HMAC-signed commands over a
one-time challenge. The relay pulses the opener's wall-button terminals, and a reed switch reports
whether the door is really shut.

```
Firmware/
├── garagelink_vectors.h      crypto test vectors shared with the Swift package
├── garagelink-esp32/         ESP-IDF project (the firmware itself)
│   └── main/
│       ├── gl_protocol.h     UUIDs, frame layouts, ATT error codes
│       ├── gl_crypto.c       mbedTLS: ECDH P-256, HKDF-SHA256, HMAC-SHA256
│       ├── gl_core.c         door state machine, pairing, command authentication
│       ├── gl_ble.c          NimBLE GATT server and advertising
│       ├── gl_hw.c           relay, reed switch, buzzer, PAIR button
│       ├── gl_store.c        identity and paired keys in NVS
│       └── gl_selftest.c     checks the crypto against the shared vectors at boot
└── host-test/                runs gl_core + gl_crypto on your Mac, no hardware needed
```

## Status

- **Builds** for ESP32-S3 with ESP-IDF v5.3.2.
- **Host tests pass** (31 checks): mbedTLS reproduces the exact bytes CryptoKit produces, and the
  device logic behaves like the Swift implementation — pairing, wrong-code lockout, replay and
  tamper rejection, safety interlock, reed-switch override.
- **Never run on real hardware yet.** No board, no wiring, no opener test.

## Wiring

| ESP32 pin | Connects to | Notes |
|---|---|---|
| GPIO 5 | Relay module `IN` | Relay contacts go across the opener's two wall-button terminals, in parallel with the existing button |
| GPIO 18 | Reed switch | Other leg to GND. Closed circuit = door shut |
| GPIO 6 | Active buzzer | Sounds before a remote close |
| GPIO 0 | BOOT button | Already on the dev board: press to open the 120-second pairing window |
| GPIO — | Optional safety beam input | Set `GL_PIN_OBSTRUCT` in `gl_hw.h` if fitted |
| 5V / GND | USB power | |

Pins live in `main/gl_hw.h`. Only touch the opener's low-voltage button terminals, never mains wiring
or the photo-eye safety sensors.

## Build and flash

```bash
. ~/esp/esp-idf/export.sh
cd Firmware/garagelink-esp32
idf.py set-target esp32s3      # or esp32
idf.py build
idf.py -p /dev/cu.usbmodem* flash monitor
```

On first boot it prints its name (`GL-XXXXXX`), its setup code and the result of the crypto
self-test, then opens the pairing window because no phone is paired yet.

## Test on your computer, without an ESP32

```bash
Firmware/host-test/build.sh
```

Compiles `gl_core.c` and `gl_crypto.c` for macOS against the copy of mbedTLS inside ESP-IDF, and
drives them with a stand-in phone.

## Setup notes (macOS, Apple Silicon)

ESP-IDF's installer picks whichever `python3` is first on your PATH. If that's an old one, run the
installer as `env PATH="/usr/bin:/bin:/usr/sbin:/sbin" ./install.sh esp32s3`. On Python 3.9 you may
also need `pip install "ruamel.yaml.clib==0.2.7"` inside `~/.espressif/python_env/...`, because newer
builds of that package register a name ESP-IDF's dependency check doesn't recognise.

## Next

- Flash a real board and pair the iPhone app with it.
- Wire to the opener and test with the door in sight.
- Add HomeKit (esp-homekit-sdk) beside this, sharing the same `gl_device_t`, so the Home app and
  this protocol drive one device.
