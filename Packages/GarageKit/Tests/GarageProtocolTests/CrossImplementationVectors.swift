import CryptoKit
import XCTest
@testable import GarageProtocol

/// Fixed inputs → fixed outputs, so a second implementation of the protocol (the ESP32 firmware,
/// which uses mbedTLS instead of CryptoKit) can prove it derives the same key and signatures.
/// The same values live in Firmware/garagelink_vectors.h. If a change here breaks these, the
/// protocol changed: bump the version and reflash the device.
final class CrossImplementationVectors: XCTestCase {
    private let devicePrivate = Data(hex: "c9f8a1d4b7e20356914af08d2c6b5e73a1d90f4c82b6e5379d0c1a4fb82e6935")!
    private let clientPrivate = Data(hex: "3b7d1e9c05a4f82671d3c05e9b4a72f18d6c30594ea7b1c82f0d5936ae41c70b")!
    private let salt = Data(hex: "0f1e2d3c4b5a69788796a5b4c3d2e1f0")!
    private let challenge = Data(hex: "11223344556677889900aabbccddeeff")!
    private let setupCode = "080111"
    private let deviceID = ShortID(hex: "289e9ade2bece609")!
    private let clientID = ShortID(hex: "8a649b4f1c2d3e40")!

    private let expectedDevicePublic = "04782d76c4234aa6025918b40700c09891b5f3d5b50ac9f3f8f96bcc33ea7654dc7e467ca0963318f575c1455ee543cb66752beaf1a795f0332c5f7d9b58f0183d"
    private let expectedClientPublic = "04192785789a8d7623abc607a895889e4359121722041a1bd2632592098e8395e1e138802c90aa814247a8a37a0512bbaf9c429acb2a13a185df57e52a300ba454"
    private let expectedSessionKey = "a43b125eb6736dd5b4e1a16dc437af30b37f31340e4134ce28d40c9294becb8f"
    private let expectedPairingTag = "ad5b390ad29fa358b55d3c52703437f1"
    private let expectedCommandTag = "fc4718666343842c441b05c5e787f4ae"
    private let expectedCommandFrame = "018a649b4f1c2d3e40fc4718666343842c441b05c5e787f4ae"

    func testKeyAgreementAndSignatureVectors() throws {
        let device = try P256.KeyAgreement.PrivateKey(rawRepresentation: devicePrivate)
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: clientPrivate)
        XCTAssertEqual(device.publicKey.x963Representation.hex, expectedDevicePublic)
        XCTAssertEqual(client.publicKey.x963Representation.hex, expectedClientPublic)

        // Both sides must land on the same key from opposite halves of the exchange.
        let fromClient = try GarageCrypto.deriveSessionKey(
            privateKey: client, peerPublicKey: device.publicKey.x963Representation,
            salt: salt, setupCode: setupCode, clientID: clientID, deviceID: deviceID)
        let fromDevice = try GarageCrypto.deriveSessionKey(
            privateKey: device, peerPublicKey: client.publicKey.x963Representation,
            salt: salt, setupCode: setupCode, clientID: clientID, deviceID: deviceID)
        XCTAssertEqual(fromClient.rawData.hex, expectedSessionKey)
        XCTAssertEqual(fromDevice.rawData.hex, expectedSessionKey)

        XCTAssertEqual(
            GarageCrypto.pairingTag(key: fromClient, clientPublicKey: client.publicKey.x963Representation, devicePublicKey: device.publicKey.x963Representation).hex,
            expectedPairingTag)
        XCTAssertEqual(
            GarageCrypto.commandTag(key: fromClient, opcode: Opcode.open.rawValue, challenge: challenge, deviceID: deviceID, clientID: clientID).hex,
            expectedCommandTag)
        XCTAssertEqual(
            CommandFrame.signed(.open, challenge: challenge, key: fromClient, clientID: clientID, deviceID: deviceID).encoded.hex,
            expectedCommandFrame)
    }

    func testWrongSetupCodeYieldsDifferentKey() throws {
        let device = try P256.KeyAgreement.PrivateKey(rawRepresentation: devicePrivate)
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: clientPrivate)
        let wrong = try GarageCrypto.deriveSessionKey(
            privateKey: client, peerPublicKey: device.publicKey.x963Representation,
            salt: salt, setupCode: "080112", clientID: clientID, deviceID: deviceID)
        XCTAssertNotEqual(wrong.rawData.hex, expectedSessionKey)
    }
}
