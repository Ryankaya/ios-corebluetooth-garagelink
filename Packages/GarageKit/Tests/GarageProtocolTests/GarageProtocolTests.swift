import CryptoKit
import XCTest
@testable import GarageProtocol

final class WireFormatTests: XCTestCase {
    func testDeviceInfoRoundTrip() throws {
        let info = DeviceInfo(firmwareMajor: 2, firmwareMinor: 7, deviceID: .random(), name: "Workshop")
        XCTAssertEqual(try DeviceInfo(decoding: info.encoded), info)
    }

    func testStatusRoundTrip() throws {
        let status = DoorStatus(door: .closing, position: 42, pairingMode: true, obstructed: true, pairedClients: 3)
        XCTAssertEqual(status.encoded.count, DoorStatus.byteCount)
        XCTAssertEqual(try DoorStatus(decoding: status.encoded), status)
    }

    func testStatusRejectsUnknownDoorState() {
        XCTAssertThrowsError(try DoorStatus(decoding: Data([9, 0, 0, 0])))
    }

    func testPairingFramesRoundTrip() throws {
        let frames: [PairingFrame] = [
            .start(clientID: .random(), publicKey: .random(count: 65)),
            .deviceKey(publicKey: .random(count: 65), salt: .random(count: 16)),
            .confirm(clientID: .random(), tag: .random(count: 16)),
        ]
        for frame in frames {
            XCTAssertEqual(try PairingFrame(decoding: frame.encoded), frame)
        }
    }

    func testFramesDecodeFromSlicedData() throws {
        // CoreBluetooth can hand us Data slices with a non-zero startIndex.
        let frame = CommandFrame(opcode: 1, clientID: .random(), tag: .random(count: 16))
        let padded = Data([0xFF, 0xFF]) + frame.encoded
        XCTAssertEqual(try CommandFrame(decoding: padded.dropFirst(2)), frame)
    }

    func testCommandFrameRejectsTrailingBytes() {
        let frame = CommandFrame(opcode: 1, clientID: .random(), tag: .random(count: 16))
        XCTAssertThrowsError(try CommandFrame(decoding: frame.encoded + Data([0])))
    }

    func testAdvertisedName() {
        let id = ShortID(hex: "a1b2c3d4e5f60718")!
        XCTAssertEqual(GarageGATT.advertisedName(for: id), "GL-A1B2C3")
    }
}

final class PairingAndCommandTests: XCTestCase {
    private var device: GarageDeviceCore!
    private let clientID = ShortID.random()

    override func setUp() {
        device = GarageDeviceCore.makeNew(name: "Test Garage")
    }

    private func pair(code: String) throws -> Result<SymmetricKey, GarageATTError> {
        let session = ClientPairingSession(clientID: clientID)
        switch device.handlePairing(session.startFrame.encoded) {
        case let .failure(error):
            return .failure(error)
        case let .success(reply):
            let (confirm, key) = try session.confirm(deviceKey: try XCTUnwrap(reply), setupCode: code, deviceID: device.deviceID)
            return device.handlePairing(confirm.encoded).map { _ in key }
        }
    }

    private func command(_ opcode: Opcode, key: SymmetricKey) -> Data {
        CommandFrame.signed(opcode, challenge: device.challenge, key: key, clientID: clientID, deviceID: device.deviceID).encoded
    }

    func testPairThenOpen() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        XCTAssertEqual(device.pairedClientCount, 1)
        XCTAssertFalse(device.pairingMode, "pairing mode ends after a successful pairing")

        XCTAssertEqual(try device.handleCommand(command(.open, key: key)).get(), .open)
        XCTAssertEqual(device.door, .opening)
        device.tick(device.travelTime + 1)
        XCTAssertEqual(device.status.door, .open)
        XCTAssertEqual(device.status.position, 100)
    }

    func testPairingRequiresPairingMode() throws {
        XCTAssertEqual(try pair(code: device.setupCode).failure, .notPairingMode)
    }

    func testWrongSetupCodeRejectedThenLocksOut() throws {
        device.pressPairButton()
        let wrong = device.setupCode == "000000" ? "111111" : "000000"
        for _ in 1..<GarageDeviceCore.maxFailedPairingAttempts {
            XCTAssertEqual(try pair(code: wrong).failure, .badSetupCode)
        }
        XCTAssertEqual(try pair(code: wrong).failure, .pairingLocked)
        XCTAssertEqual(try pair(code: device.setupCode).failure, .pairingLocked, "even the right code is refused while locked")

        device.pressPairButton()
        XCTAssertNoThrow(try pair(code: device.setupCode).get())
    }

    func testReplayedCommandRejected() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        let frame = command(.open, key: key)
        XCTAssertNoThrow(try device.handleCommand(frame).get())
        XCTAssertEqual(device.handleCommand(frame).failure, .unauthorized)
    }

    func testTamperedOpcodeRejected() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        var bytes = [UInt8](command(.close, key: key))
        bytes[0] = Opcode.open.rawValue
        XCTAssertEqual(device.handleCommand(Data(bytes)).failure, .unauthorized)
    }

    func testUnpairedPhoneRejected() {
        let strangerKey = SymmetricKey(size: .bits256)
        XCTAssertEqual(device.handleCommand(command(.open, key: strangerKey)).failure, .unauthorized)
    }

    func testObstructionReversesClosingDoorAndBlocksClose() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        _ = device.handleCommand(command(.open, key: key))
        device.tick(device.travelTime + 1)

        XCTAssertNoThrow(try device.handleCommand(command(.close, key: key)).get())
        device.tick(1)
        XCTAssertEqual(device.door, .closing)
        device.setObstruction(true)
        device.tick(0.1)
        XCTAssertEqual(device.door, .opening)
        XCTAssertEqual(device.handleCommand(command(.close, key: key)).failure, .obstructed)
    }

    func testWallButtonCycles() {
        device.pressWallButton()
        XCTAssertEqual(device.door, .opening)
        device.tick(1)
        device.pressWallButton()
        XCTAssertEqual(device.door, .stopped)
        device.pressWallButton()
        XCTAssertEqual(device.door, .closing)
    }

    func testSnapshotPreservesPairing() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        let restored = GarageDeviceCore(snapshot: device.snapshot)
        device = restored
        XCTAssertNoThrow(try device.handleCommand(command(.open, key: key)).get())
    }

    func testUnpairRemovesKey() throws {
        device.pressPairButton()
        let key = try pair(code: device.setupCode).get()
        XCTAssertNoThrow(try device.handleCommand(command(.unpair, key: key)).get())
        XCTAssertEqual(device.pairedClientCount, 0)
        XCTAssertEqual(device.handleCommand(command(.open, key: key)).failure, .unauthorized)
    }

    func testPairingModeTimesOut() {
        device.pressPairButton()
        device.tick(GarageDeviceCore.pairingModeDuration + 1)
        XCTAssertFalse(device.pairingMode)
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
