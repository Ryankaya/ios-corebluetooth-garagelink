import Foundation

// MARK: - GATT layout
//
// Service 6E4A1000-…            one per device
// ├─ Info      (read)           DeviceInfo
// ├─ State     (read, notify)   DoorStatus
// ├─ Challenge (read)           16-byte nonce, rotated after every command attempt
// ├─ Command   (write)          CommandFrame — HMAC-signed over the current challenge
// └─ Pairing   (write, notify)  PairingFrame — ECDH P-256 + setup-code confirmation
//
// Failures come back as ATT error codes on the write response (GarageATTError).

public enum GarageGATT {
    public static let protocolVersion: UInt8 = 1
    public static let serviceUUID = "6E4A1000-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
    public static let advertisedNamePrefix = "GL-"

    /// Advertised local name: "GL-" + first 3 bytes of the device ID. Lets a phone find a
    /// known device again even when its Bluetooth address (and CoreBluetooth identifier) rotates.
    public static func advertisedName(for deviceID: ShortID) -> String {
        advertisedNamePrefix + deviceID.hex.prefix(6).uppercased()
    }
}

public enum GarageCharacteristic: String, CaseIterable, Sendable {
    case info = "6E4A1001-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
    case state = "6E4A1002-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
    case challenge = "6E4A1003-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
    case command = "6E4A1004-8B1C-4F6E-9D2A-3C0FFEE0B1E5"
    case pairing = "6E4A1005-8B1C-4F6E-9D2A-3C0FFEE0B1E5"

    public var label: String {
        switch self {
        case .info: return "Info"
        case .state: return "State"
        case .challenge: return "Challenge"
        case .command: return "Command"
        case .pairing: return "Pairing"
        }
    }
}

/// Application ATT error codes (0x80–0x9F is the range the Bluetooth spec reserves for apps).
/// We deliberately avoid 0x05 / 0x0F (Insufficient Authentication / Encryption): iOS reacts to
/// those by starting OS-level bonding, which would pop a system pairing dialog.
public enum GarageATTError: UInt8, Error, CaseIterable, Sendable {
    case invalidLength = 0x0D
    case unauthorized = 0x80
    case notPairingMode = 0x81
    case badSetupCode = 0x82
    case pairingLocked = 0x83
    case noPairingSession = 0x84
    case obstructed = 0x85
    case unsupportedOpcode = 0x86
    case malformed = 0x87

    public var message: String {
        switch self {
        case .invalidLength: return "The device rejected a frame with the wrong length."
        case .unauthorized: return "This phone isn't paired with the device (or the signature was invalid)."
        case .notPairingMode: return "The device isn't in pairing mode. Press its PAIR button, then try again."
        case .badSetupCode: return "Incorrect setup code."
        case .pairingLocked: return "Too many wrong codes. Press the device's PAIR button to unlock pairing."
        case .noPairingSession: return "Pairing session expired. Start again."
        case .obstructed: return "Can't close: the safety sensor is blocked."
        case .unsupportedOpcode: return "The device doesn't support that command."
        case .malformed: return "The device couldn't parse the request."
        }
    }
}

// MARK: - Info

public struct DeviceInfo: Equatable, Sendable {
    public static let maxNameBytes = 20

    public var protocolVersion: UInt8
    public var firmwareMajor: UInt8
    public var firmwareMinor: UInt8
    public var deviceID: ShortID
    public var name: String

    public init(protocolVersion: UInt8 = GarageGATT.protocolVersion, firmwareMajor: UInt8, firmwareMinor: UInt8, deviceID: ShortID, name: String) {
        self.protocolVersion = protocolVersion
        self.firmwareMajor = firmwareMajor
        self.firmwareMinor = firmwareMinor
        self.deviceID = deviceID
        self.name = name
    }

    public var firmwareString: String { "\(firmwareMajor).\(firmwareMinor)" }

    /// [version][fw major][fw minor][reserved][device id ×8][name utf8 ≤20]
    public var encoded: Data {
        var data = Data([protocolVersion, firmwareMajor, firmwareMinor, 0])
        data += deviceID.bytes
        data += Data(name.utf8.prefix(DeviceInfo.maxNameBytes))
        return data
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        protocolVersion = try reader.u8()
        firmwareMajor = try reader.u8()
        firmwareMinor = try reader.u8()
        _ = try reader.u8()
        deviceID = ShortID(bytes: try reader.data(ShortID.length))!
        name = String(decoding: reader.rest(), as: UTF8.self)
    }
}

// MARK: - State

public enum DoorState: UInt8, Sendable, Codable {
    case closed = 0, opening = 1, open = 2, closing = 3, stopped = 4

    public var label: String {
        switch self {
        case .closed: return "Closed"
        case .opening: return "Opening"
        case .open: return "Open"
        case .closing: return "Closing"
        case .stopped: return "Stopped"
        }
    }

    public var isMoving: Bool { self == .opening || self == .closing }
}

public struct DoorStatus: Equatable, Sendable {
    public static let byteCount = 4

    public var door: DoorState
    /// 0 = fully closed, 100 = fully open.
    public var position: UInt8
    public var pairingMode: Bool
    public var obstructed: Bool
    public var pairedClients: UInt8

    public init(door: DoorState, position: UInt8, pairingMode: Bool, obstructed: Bool, pairedClients: UInt8) {
        self.door = door
        self.position = position
        self.pairingMode = pairingMode
        self.obstructed = obstructed
        self.pairedClients = pairedClients
    }

    /// [door state][position %][flags: bit0 pairing mode, bit1 obstructed][paired client count]
    public var encoded: Data {
        let flags: UInt8 = (pairingMode ? 0x01 : 0) | (obstructed ? 0x02 : 0)
        return Data([door.rawValue, position, flags, pairedClients])
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let raw = try reader.u8()
        guard let door = DoorState(rawValue: raw) else { throw WireError.invalidValue("door state \(raw)") }
        self.door = door
        position = min(try reader.u8(), 100)
        let flags = try reader.u8()
        pairingMode = flags & 0x01 != 0
        obstructed = flags & 0x02 != 0
        pairedClients = try reader.u8()
        try reader.expectEnd()
    }
}

// MARK: - Command

public enum Opcode: UInt8, CaseIterable, Sendable {
    case open = 0x01
    case close = 0x02
    case stop = 0x03
    case toggle = 0x04
    /// Removes the sending phone's key from the device.
    case unpair = 0x10

    public var label: String {
        switch self {
        case .open: return "OPEN"
        case .close: return "CLOSE"
        case .stop: return "STOP"
        case .toggle: return "TOGGLE"
        case .unpair: return "UNPAIR"
        }
    }
}

public struct CommandFrame: Equatable, Sendable {
    public static let tagLength = 16
    public static let byteCount = 1 + ShortID.length + tagLength

    /// Kept raw so a device can distinguish "bad signature" from "unknown opcode".
    public var opcode: UInt8
    public var clientID: ShortID
    public var tag: Data

    public init(opcode: UInt8, clientID: ShortID, tag: Data) {
        self.opcode = opcode
        self.clientID = clientID
        self.tag = tag
    }

    /// [opcode][client id ×8][HMAC-SHA256 tag, truncated ×16]
    public var encoded: Data {
        Data([opcode]) + clientID.bytes + tag
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        opcode = try reader.u8()
        clientID = ShortID(bytes: try reader.data(ShortID.length))!
        tag = try reader.data(CommandFrame.tagLength)
        try reader.expectEnd()
    }
}

// MARK: - Pairing

public enum PairingFrame: Equatable, Sendable {
    /// Phone → device: its ephemeral P-256 public key (X9.63, 65 bytes).
    case start(clientID: ShortID, publicKey: Data)
    /// Device → phone (notify): the device's ephemeral public key and an HKDF salt.
    case deviceKey(publicKey: Data, salt: Data)
    /// Phone → device: proof that it derived the same key using the device's setup code.
    case confirm(clientID: ShortID, tag: Data)

    private enum Kind: UInt8 { case start = 0x01, deviceKey = 0x02, confirm = 0x03 }

    public var encoded: Data {
        switch self {
        case let .start(clientID, publicKey):
            return Data([Kind.start.rawValue]) + clientID.bytes + publicKey
        case let .deviceKey(publicKey, salt):
            return Data([Kind.deviceKey.rawValue]) + publicKey + salt
        case let .confirm(clientID, tag):
            return Data([Kind.confirm.rawValue]) + clientID.bytes + tag
        }
    }

    public init(decoding data: Data) throws {
        var reader = ByteReader(data)
        let raw = try reader.u8()
        switch Kind(rawValue: raw) {
        case .start:
            let clientID = ShortID(bytes: try reader.data(ShortID.length))!
            self = .start(clientID: clientID, publicKey: try reader.data(GarageCrypto.publicKeyLength))
        case .deviceKey:
            let publicKey = try reader.data(GarageCrypto.publicKeyLength)
            self = .deviceKey(publicKey: publicKey, salt: try reader.data(GarageCrypto.saltLength))
        case .confirm:
            let clientID = ShortID(bytes: try reader.data(ShortID.length))!
            self = .confirm(clientID: clientID, tag: try reader.data(CommandFrame.tagLength))
        case nil:
            throw WireError.invalidValue("pairing frame kind \(raw)")
        }
        try reader.expectEnd()
    }
}
