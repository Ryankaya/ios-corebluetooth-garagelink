import CryptoKit
import Foundation

/// The device's "firmware": door motor state machine, pairing and command authentication.
///
/// Transport-free and clock-free (the host calls `tick`), so the same logic runs behind the Mac's
/// real Bluetooth peripheral, behind the in-app virtual device, and in unit tests.
public final class GarageDeviceCore {
    public struct Snapshot: Codable, Equatable {
        public var deviceID: ShortID
        public var name: String
        public var setupCode: String
        /// client id hex → 32-byte key hex
        public var pairedKeys: [String: String]
    }

    public static let maxFailedPairingAttempts = 5
    public static let pairingModeDuration: TimeInterval = 120

    public let deviceID: ShortID
    public let name: String
    /// Printed on the device label (and encoded in its NFC tag / QR code).
    public let setupCode: String
    public let firmware: (major: UInt8, minor: UInt8) = (1, 0)
    public var travelTime: TimeInterval = 8

    public private(set) var door: DoorState = .closed
    /// 0 = closed, 1 = open.
    public private(set) var position: Double = 0
    public private(set) var obstructionSensor = false
    public private(set) var challenge = Data.random(count: GarageCrypto.challengeLength)
    public private(set) var pairingModeRemaining: TimeInterval = 0
    private var pairedKeys: [ShortID: SymmetricKey]
    private var failedPairingAttempts = 0
    private var lastDirection: DoorState = .closing
    private var pendingPairings: [ShortID: PendingPairing] = [:]

    private struct PendingPairing {
        let privateKey: P256.KeyAgreement.PrivateKey
        let clientPublicKey: Data
        let salt: Data
    }

    /// Human-readable device events ("Paired phone 1a2b…", "Obstruction — reversing").
    public var log: ((String) -> Void)?

    public init(snapshot: Snapshot) {
        deviceID = snapshot.deviceID
        name = snapshot.name
        setupCode = snapshot.setupCode
        var keys: [ShortID: SymmetricKey] = [:]
        for (clientHex, keyHex) in snapshot.pairedKeys {
            if let id = ShortID(hex: clientHex), let key = Data(hex: keyHex), key.count == GarageCrypto.keyByteCount {
                keys[id] = SymmetricKey(data: key)
            }
        }
        pairedKeys = keys
    }

    public static func makeNew(name: String) -> GarageDeviceCore {
        GarageDeviceCore(snapshot: Snapshot(
            deviceID: .random(),
            name: String(decoding: Data(name.utf8.prefix(DeviceInfo.maxNameBytes)), as: UTF8.self),
            setupCode: GarageCrypto.randomSetupCode(),
            pairedKeys: [:]
        ))
    }

    public var snapshot: Snapshot {
        Snapshot(
            deviceID: deviceID,
            name: name,
            setupCode: setupCode,
            pairedKeys: Dictionary(uniqueKeysWithValues: pairedKeys.map { ($0.key.hex, $0.value.rawData.hex) })
        )
    }

    // MARK: Readable state

    public var pairingMode: Bool { pairingModeRemaining > 0 }
    public var pairedClientCount: Int { pairedKeys.count }

    public var info: DeviceInfo {
        DeviceInfo(firmwareMajor: firmware.major, firmwareMinor: firmware.minor, deviceID: deviceID, name: name)
    }

    public var status: DoorStatus {
        DoorStatus(
            door: door,
            position: UInt8((position * 100).rounded()),
            pairingMode: pairingMode,
            obstructed: obstructionSensor,
            pairedClients: UInt8(clamping: pairedKeys.count)
        )
    }

    /// Canonical "pair this device" link, suitable for an NFC tag or QR code.
    public var pairingURL: String {
        "garagelink://pair?d=\(deviceID.hex)&c=\(setupCode)"
    }

    // MARK: Physical controls

    /// The PAIR button on the device. Also clears a wrong-code lockout: unlocking requires physical access.
    public func pressPairButton() {
        pairingModeRemaining = GarageDeviceCore.pairingModeDuration
        failedPairingAttempts = 0
        log?("Pairing mode on for \(Int(GarageDeviceCore.pairingModeDuration))s")
    }

    /// The wall button: open → stop → close cycle, like a real opener. No authentication (it's wired).
    public func pressWallButton() {
        toggle()
        log?("Wall button → \(door.label.lowercased())")
    }

    public func setObstruction(_ blocked: Bool) {
        obstructionSensor = blocked
        log?(blocked ? "Safety sensor blocked" : "Safety sensor clear")
    }

    public func forgetAllPhones() {
        pairedKeys.removeAll()
        pendingPairings.removeAll()
        log?("All paired phones removed")
    }

    // MARK: Motor

    /// Advances the motor simulation. Returns true when the encoded status changed (worth a notify).
    @discardableResult
    public func tick(_ dt: TimeInterval) -> Bool {
        let before = status
        if pairingModeRemaining > 0 {
            pairingModeRemaining = max(0, pairingModeRemaining - dt)
            if pairingModeRemaining == 0 {
                pendingPairings.removeAll()
                log?("Pairing mode timed out")
            }
        }
        let step = dt / travelTime
        switch door {
        case .opening:
            position = min(1, position + step)
            if position >= 1 {
                door = .open
                log?("Door open")
            }
        case .closing:
            if obstructionSensor {
                // UL 325-style safety behavior: reverse when the beam is broken while closing.
                door = .opening
                lastDirection = .opening
                log?("Obstruction while closing — reversing")
            } else {
                position = max(0, position - step)
                if position <= 0 {
                    door = .closed
                    log?("Door closed")
                }
            }
        case .closed, .open, .stopped:
            break
        }
        return status != before
    }

    private func startOpening() {
        guard door != .open else { return }
        door = .opening
        lastDirection = .opening
    }

    private func startClosing() {
        guard door != .closed else { return }
        door = .closing
        lastDirection = .closing
    }

    private func stop() {
        if door.isMoving { door = .stopped }
    }

    private func toggle() {
        switch door {
        case .closed: startOpening()
        case .open: startClosing()
        case .opening, .closing: stop()
        case .stopped: lastDirection == .opening ? startClosing() : startOpening()
        }
    }

    /// What `toggle` would do next, so an authenticated toggle can refuse to close onto an obstruction.
    private var toggleWouldClose: Bool {
        door == .open || (door == .stopped && lastDirection == .opening)
    }

    // MARK: GATT writes

    /// Command characteristic. Every attempt, valid or not, consumes the challenge: a captured frame
    /// is useless afterwards, and brute-forcing a tag needs a fresh read per guess.
    public func handleCommand(_ data: Data) -> Result<Opcode, GarageATTError> {
        let challenge = self.challenge
        self.challenge = .random(count: GarageCrypto.challengeLength)

        guard data.count == CommandFrame.byteCount else { return .failure(.invalidLength) }
        guard let frame = try? CommandFrame(decoding: data) else { return .failure(.malformed) }
        guard let key = pairedKeys[frame.clientID] else {
            log?("Rejected command from unknown phone \(frame.clientID.hex.prefix(8))")
            return .failure(.unauthorized)
        }
        let expected = GarageCrypto.commandTag(key: key, opcode: frame.opcode, challenge: challenge, deviceID: deviceID, clientID: frame.clientID)
        guard expected.constantTimeEquals(frame.tag) else {
            log?("Rejected command: bad signature (replayed or tampered)")
            return .failure(.unauthorized)
        }
        guard let opcode = Opcode(rawValue: frame.opcode) else { return .failure(.unsupportedOpcode) }

        switch opcode {
        case .open:
            startOpening()
        case .close:
            guard !obstructionSensor else { return .failure(.obstructed) }
            startClosing()
        case .stop:
            stop()
        case .toggle:
            if toggleWouldClose && obstructionSensor { return .failure(.obstructed) }
            toggle()
        case .unpair:
            pairedKeys[frame.clientID] = nil
            log?("Phone \(frame.clientID.hex.prefix(8)) unpaired itself")
            return .success(opcode)
        }
        log?("\(opcode.label) from phone \(frame.clientID.hex.prefix(8)) → \(door.label.lowercased())")
        return .success(opcode)
    }

    /// Pairing characteristic. On success, returns a frame to notify back to the writer (if any).
    public func handlePairing(_ data: Data) -> Result<PairingFrame?, GarageATTError> {
        guard let frame = try? PairingFrame(decoding: data) else { return .failure(.malformed) }

        switch frame {
        case let .start(clientID, clientPublicKey):
            guard failedPairingAttempts < GarageDeviceCore.maxFailedPairingAttempts else { return .failure(.pairingLocked) }
            guard pairingMode else { return .failure(.notPairingMode) }
            guard (try? P256.KeyAgreement.PublicKey(x963Representation: clientPublicKey)) != nil else { return .failure(.malformed) }
            let privateKey = P256.KeyAgreement.PrivateKey()
            let salt = Data.random(count: GarageCrypto.saltLength)
            pendingPairings[clientID] = PendingPairing(privateKey: privateKey, clientPublicKey: clientPublicKey, salt: salt)
            log?("Pairing started by phone \(clientID.hex.prefix(8))")
            return .success(.deviceKey(publicKey: privateKey.publicKey.x963Representation, salt: salt))

        case let .confirm(clientID, tag):
            guard let pending = pendingPairings.removeValue(forKey: clientID) else { return .failure(.noPairingSession) }
            guard pairingMode else { return .failure(.notPairingMode) }
            guard let key = try? GarageCrypto.deriveSessionKey(
                privateKey: pending.privateKey,
                peerPublicKey: pending.clientPublicKey,
                salt: pending.salt,
                setupCode: setupCode,
                clientID: clientID,
                deviceID: deviceID
            ) else { return .failure(.malformed) }
            let expected = GarageCrypto.pairingTag(
                key: key,
                clientPublicKey: pending.clientPublicKey,
                devicePublicKey: pending.privateKey.publicKey.x963Representation
            )
            guard expected.constantTimeEquals(tag) else {
                failedPairingAttempts += 1
                if failedPairingAttempts >= GarageDeviceCore.maxFailedPairingAttempts {
                    pairingModeRemaining = 0
                    pendingPairings.removeAll()
                    log?("Wrong setup code — pairing locked until PAIR is pressed")
                    return .failure(.pairingLocked)
                }
                log?("Wrong setup code (\(failedPairingAttempts)/\(GarageDeviceCore.maxFailedPairingAttempts))")
                return .failure(.badSetupCode)
            }
            pairedKeys[clientID] = key
            failedPairingAttempts = 0
            pairingModeRemaining = 0
            pendingPairings.removeAll()
            log?("Paired phone \(clientID.hex.prefix(8))")
            return .success(nil)

        case .deviceKey:
            return .failure(.unsupportedOpcode)
        }
    }
}
