import CryptoKit
import Foundation

/// Crypto shared by the phone and the device.
///
/// Pairing: ephemeral ECDH (P-256) → HKDF-SHA256, with the device's printed 6-digit setup code
/// mixed into the HKDF info. A phone that doesn't know the code derives a different key, so its
/// confirm tag fails. Commands: HMAC-SHA256 over a one-time device challenge, so a captured
/// command can't be replayed.
///
/// Honest limitation: a 6-digit code is low entropy, and an active man-in-the-middle during the
/// pairing window could brute-force it offline. Production systems use a PAKE (HomeKit uses SRP;
/// Matter uses SPAKE2+). The device-side lockout and pairing-mode button limit exposure here.
public enum GarageCrypto {
    public static let publicKeyLength = 65
    public static let saltLength = 16
    public static let challengeLength = 16
    public static let keyByteCount = 32

    public static func isValidSetupCode(_ code: String) -> Bool {
        code.count == 6 && code.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    public static func randomSetupCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func deriveSessionKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        salt: Data,
        setupCode: String,
        clientID: ShortID,
        deviceID: ShortID
    ) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var info = Data("GarageLink-v1".utf8)
        info += Data(setupCode.utf8)
        info += clientID.bytes
        info += deviceID.bytes
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: salt,
            info: info,
            outputByteCount: keyByteCount
        )
    }

    public static func pairingTag(key: SymmetricKey, clientPublicKey: Data, devicePublicKey: Data) -> Data {
        tag(key: key, label: "GLPAIR", clientPublicKey, devicePublicKey)
    }

    public static func commandTag(key: SymmetricKey, opcode: UInt8, challenge: Data, deviceID: ShortID, clientID: ShortID) -> Data {
        tag(key: key, label: "GLCMD", Data([opcode]), challenge, deviceID.bytes, clientID.bytes)
    }

    private static func tag(key: SymmetricKey, label: String, _ parts: Data...) -> Data {
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(label.utf8))
        for part in parts { hmac.update(data: part) }
        return Data(Data(hmac.finalize()).prefix(CommandFrame.tagLength))
    }
}

extension SymmetricKey {
    public var rawData: Data { withUnsafeBytes { Data($0) } }
}

// MARK: - Phone side

/// One pairing attempt from the phone's point of view.
public struct ClientPairingSession {
    public let clientID: ShortID
    private let privateKey = P256.KeyAgreement.PrivateKey()

    public init(clientID: ShortID) {
        self.clientID = clientID
    }

    public var publicKey: Data { privateKey.publicKey.x963Representation }

    public var startFrame: PairingFrame {
        .start(clientID: clientID, publicKey: publicKey)
    }

    /// Consumes the device's key frame and returns the confirm frame plus the session key to store.
    public func confirm(deviceKey frame: PairingFrame, setupCode: String, deviceID: ShortID) throws -> (frame: PairingFrame, key: SymmetricKey) {
        guard case let .deviceKey(devicePublicKey, salt) = frame else {
            throw WireError.invalidValue("expected device key frame")
        }
        let key = try GarageCrypto.deriveSessionKey(
            privateKey: privateKey,
            peerPublicKey: devicePublicKey,
            salt: salt,
            setupCode: setupCode,
            clientID: clientID,
            deviceID: deviceID
        )
        let tag = GarageCrypto.pairingTag(key: key, clientPublicKey: publicKey, devicePublicKey: devicePublicKey)
        return (.confirm(clientID: clientID, tag: tag), key)
    }
}

extension CommandFrame {
    public static func signed(_ opcode: Opcode, challenge: Data, key: SymmetricKey, clientID: ShortID, deviceID: ShortID) -> CommandFrame {
        let tag = GarageCrypto.commandTag(key: key, opcode: opcode.rawValue, challenge: challenge, deviceID: deviceID, clientID: clientID)
        return CommandFrame(opcode: opcode.rawValue, clientID: clientID, tag: tag)
    }
}
