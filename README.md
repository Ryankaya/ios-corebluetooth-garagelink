# GarageLink: phone ↔ hardware over Bluetooth LE

An iPhone app that finds, securely pairs with and controls a garage door controller over Bluetooth
Low Energy, with "tap to pair" via NFC or QR. It comes with a macOS app that turns a Mac's Bluetooth
radio into the controller, so the whole system can be demoed on a real iPhone with no extra hardware.

**Status:** tested end to end over real Bluetooth: an iPhone paired with GarageSim on a MacBook, then
opened and closed the door with signed commands. The in-app QR scanner, NFC tag pairing and
reconnecting after going out of range haven't been tested on a device yet.

```
┌──────────────── iPhone: GarageLink ────────────────┐         ┌──────── Mac: GarageSim ────────┐
│ SwiftUI  ─▶  GarageClient (protocol)               │         │ SwiftUI faceplate (LCD, PAIR,   │
│                 │                                  │   BLE   │ wall button, safety beam, QR)   │
│      GATTConnection / PeripheralScanner            │ ◀─────▶ │ BluetoothDeviceHost             │
│        ├─ BLECentral   (CoreBluetooth)             │  GATT   │   (CBPeripheralManager)         │
│        └─ VirtualGarage (in-process, for Simulator)│         │        │                        │
│ Keychain · CoreNFC · deep links                    │         │        ▼                        │
└──────────────────────┬─────────────────────────────┘         │ GarageDeviceCore  ◀── same code │
                       └──── GarageProtocol (Swift package) ───┴─ wire format · crypto · tests ─┘
```

## What it demonstrates

| Area | Where |
|---|---|
| **CoreBluetooth central**: scan with live RSSI, connect with timeouts, GATT discovery, read, write-with-response, notify, RSSI polling, state restoration, `bluetooth-central` background mode | `GarageLink/Transport/BLECentral.swift` |
| **CoreBluetooth peripheral**: advertise, GATT server, batched write requests, ATT error responses, notification backpressure (`peripheralManagerIsReady`) | `DeviceSimulator/GarageSim/BluetoothDeviceHost.swift` |
| **Callback → async/await bridge** that resumes exactly once (callback, timeout, cancel or disconnect) | `Transport/Transport.swift` (`awaitCallback`, `Pending`) |
| **Binary protocol design**: versioned frames, bounds-checked parsing | `Packages/GarageKit/Sources/GarageProtocol/Wire.swift` |
| **Secure pairing**: ephemeral ECDH P-256 → HKDF-SHA256 bound to the device's setup code, wrong-code lockout, pairing only after a physical button press | `GarageCrypto.swift`, `GarageDeviceCore.swift` |
| **Replay-proof commands**: HMAC-SHA256 over a one-time device challenge | same |
| **Keychain**: per-device keys, `AfterFirstUnlockThisDeviceOnly` | `Core/DeviceRegistry.swift` |
| **Tap / scan to pair**: CoreNFC NDEF reader, in-app VisionKit QR scanner, `garagelink://` deep link | `Core/PairingLink.swift`, `Features/AddDevice/PairingQRScanner.swift` |
| **Resilient connection**: reconnect by identifier, fall back to scanning and verifying the device ID it reports, exponential backoff, drop the link when backgrounded | `Features/Control/DeviceControlViewModel.swift`, `App/AppEnvironment.swift` |
| **Device safety logic**: auto-reverse on obstruction, refuses to close with the beam blocked | `GarageDeviceCore.swift` |
| **Testability**: firmware logic has no transport or clock, so it runs under 18 unit tests, behind real BLE and in-app | `Packages/GarageKit/Tests` |
| **Protocol inspector**: every frame in hex, in the app | `Features/Inspector/TrafficLogView.swift` |

## GATT protocol (v1)

Service `6E4A1000-8B1C-4F6E-9D2A-3C0FFEE0B1E5`. The device advertises as `GL-` + the first 3 bytes of its ID.

| Characteristic | UUID suffix | Props | Payload |
|---|---|---|---|
| Info | `…1001` | read | `[ver][fw major][fw minor][rsvd][device id ×8][name ≤20]` |
| State | `…1002` | read, notify | `[door state][position %][flags: pairing, obstructed][paired phones]` |
| Challenge | `…1003` | read | 16-byte nonce, replaced after every command attempt |
| Command | `…1004` | write | `[opcode][client id ×8][HMAC tag ×16]` |
| Pairing | `…1005` | write, notify | `01 start [client id][P-256 pub ×65]` → notify `02 [device pub ×65][salt ×16]` → `03 confirm [client id][tag ×16]` |

Errors come back on the write response as ATT application errors (`0x80` unauthorized, `0x81` not
in pairing mode, `0x82` bad setup code, `0x83` locked, `0x85` obstructed…). It deliberately avoids
`0x05`/`0x0F`: iOS answers those by starting system-level bonding and showing a pairing dialog.

### Security notes and known limits
- The setup code never goes over the air. It's mixed into the HKDF, and the phone proves it knows the code with an HMAC.
- Every command attempt (valid or not) burns the challenge, so recorded frames can't be replayed and each guess costs a round trip.
- **Limitation:** a 6-digit code is low entropy. An active man-in-the-middle present during the pairing window could brute-force it offline. Production systems use a PAKE (HomeKit uses SRP, Matter uses SPAKE2+). The physical PAIR button, 120-second window and 5-attempt lockout reduce that exposure but don't remove it.
- The phone doesn't authenticate the device's state notifications; a spoofed device could show a fake door state. That's acceptable for a demo, but real products sign or encrypt them.

## Run it

Requirements: Xcode 16+ (built with Xcode 27), iOS 16.2+, macOS 13+. The project is generated from `project.yml` with XcodeGen.

### 1. Real Bluetooth demo: iPhone + Mac
1. Open `GarageLink.xcodeproj`, choose the **GarageSim** scheme, and run it on *My Mac*. Allow Bluetooth when asked. The window shows `Advertising as GL-XXXXXX`, a setup code and a QR code.
2. Choose the **GarageLink** scheme and run it on a physical iPhone (Simulator has no Bluetooth).
3. On the iPhone, tap **+** → **Scan QR code on device** and scan the QR code on the Mac screen, or pick the device from the list and type the code. (The system Camera also works once the app is installed.)
4. Open, stop and close the door, and watch the Mac's LCD and device log react. Flip **Safety beam blocked** and try closing.
5. On the phone, ⋯ → **Protocol inspector** shows every frame.

The PAIR window lasts 120 seconds; click **PAIR** on the Mac to reopen it.

### Troubleshooting
- **Run only one GarageSim**, and don't leave it paused in Xcode's debugger. A paused or duplicate copy can't answer the phone (seen as `Reading Info failed: ATT error 0xF2`).
- **The Mac may appear under its own name** (e.g. "MacBook") instead of `GL-XXXXXX`. iPhones signed in to the same Apple ID do this. The app matches devices by the ID the device reports after connecting, so pick it anyway.
- **Every Bluetooth request GarageSim receives is logged** to `~/Library/Application Support/GarageLinkSim/gatt.log`.

### 2. Simulator-only demo
Run **GarageLink** in the iOS Simulator. It defaults to the **Virtual device**, which runs the same
`GarageDeviceCore` in-process. Open **Virtual device panel** for the setup code and hardware buttons.

### Tests
```bash
cd Packages/GarageKit && swift test
```

### NFC pairing tag
Write the pairing link (GarageSim → *Copy pairing link*) to an NTAG sticker as a URI record with any
NFC writer app. Then tap it in the pairing screen, or hold the iPhone near it from the lock screen.
NFC reading requires a paid Apple Developer team (the NFC capability isn't available to free teams).

## Next steps toward production hardware
- **ESP32 firmware** implementing the same GATT table (NimBLE host + mbedTLS for ECDH/HKDF/HMAC), driving a relay across the opener's wall-button terminals, with a reed switch for closed/open sensing.
- Replace setup-code pairing with SPAKE2+, and add LE Secure Connections encryption.
- App Intents / Siri / Control Center "Open garage", and a Live Activity while the door moves.
- Firmware updates over BLE (DFU) with signed images; Matter / HomeKit bridge.

## Layout
```
GarageLink/
├── project.yml                     XcodeGen spec (iOS app + macOS simulator)
├── Packages/GarageKit/             GarageProtocol: wire format, crypto, device core + tests
├── GarageLink/                     iOS app
│   ├── App/                        entry point, dependency container
│   ├── Transport/                  BLE central, virtual device, async bridge
│   ├── Core/                       protocol client, Keychain registry, NFC/deep links, traffic log
│   └── Features/                   Home, AddDevice/Pairing, Control, Inspector, VirtualDevice
└── DeviceSimulator/GarageSim/      macOS BLE peripheral app
```
