import CryptoKit
import Foundation
import GarageProtocol

/// Speaks the GarageLink protocol over any `GATTConnection` (real BLE or virtual).
@MainActor
final class GarageClient {
    enum ClientError: LocalizedError {
        case notPrepared
        case incompatibleFirmware(UInt8)
        case wrongDevice
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notPrepared: return "Not connected to the device yet."
            case let .incompatibleFirmware(version): return "The device speaks protocol v\(version); this app needs v\(GarageGATT.protocolVersion). Update the app or the device firmware."
            case .wrongDevice: return "A different GarageLink device answered. Move closer to the right one."
            case let .badResponse(detail): return "Unexpected response from the device (\(detail))."
            }
        }
    }

    let connection: GATTConnection
    private(set) var info: DeviceInfo?
    var onStatus: ((DoorStatus) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let log: TrafficLog
    private var pairingReply: Pending<PairingFrame>?
    private var eventTask: Task<Void, Never>?

    init(connection: GATTConnection, log: TrafficLog) {
        self.connection = connection
        self.log = log
        let events = connection.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case let .notification(characteristic, value):
            log.record(.rx, characteristic, value, note: "notify")
            switch characteristic {
            case .state:
                if let status = try? DoorStatus(decoding: value) { onStatus?(status) }
            case .pairing:
                if let frame = try? PairingFrame(decoding: value) { pairingReply?.resume(.success(frame)) }
            case .info, .challenge, .command:
                break
            }
        case let .disconnected(error):
            log.record(.event, note: "Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            pairingReply?.resume(.failure(LinkError.disconnected))
            onDisconnect?(error)
        }
    }

    /// Reads device info, checks protocol compatibility and subscribes to notifications.
    @discardableResult
    func prepare(expecting deviceID: ShortID? = nil) async throws -> DeviceInfo {
        log.record(.event, note: "Connected")
        let info = try DeviceInfo(decoding: try await read(.info, note: "device info"))
        guard info.protocolVersion == GarageGATT.protocolVersion else {
            throw ClientError.incompatibleFirmware(info.protocolVersion)
        }
        if let deviceID, info.deviceID != deviceID {
            throw ClientError.wrongDevice
        }
        try await connection.setNotifications(true, for: .state)
        try await connection.setNotifications(true, for: .pairing)
        log.record(.event, note: "Subscribed to State + Pairing")
        self.info = info
        return info
    }

    func readStatus() async throws -> DoorStatus {
        try DoorStatus(decoding: try await read(.state, note: "door state"))
    }

    /// ECDH pairing. Returns the long-term key to store in the Keychain.
    func pair(setupCode: String, clientID: ShortID) async throws -> SymmetricKey {
        guard let info else { throw ClientError.notPrepared }
        let session = ClientPairingSession(clientID: clientID)

        // Arm the waiter before writing: the device may notify immediately after its write response.
        let deviceKey: PairingFrame = try await awaitCallback(timeout: 10, operation: "Key exchange") { (pending: Pending<PairingFrame>) in
            pairingReply = pending
            Task {
                do {
                    try await write(.pairing, session.startFrame.encoded, note: "pair start (phone public key)")
                } catch {
                    pending.resume(.failure(error))
                }
            }
        }
        pairingReply = nil

        let (confirm, key) = try session.confirm(deviceKey: deviceKey, setupCode: setupCode, deviceID: info.deviceID)
        try await write(.pairing, confirm.encoded, note: "pair confirm (HMAC proof of setup code)")
        log.record(.event, note: "Paired — session key stored in Keychain")
        return key
    }

    /// Challenge-response command: read a fresh nonce, sign opcode + nonce, write.
    func send(_ opcode: Opcode, key: SymmetricKey, clientID: ShortID) async throws {
        guard let info else { throw ClientError.notPrepared }
        let challenge = try await read(.challenge, note: "challenge nonce")
        guard challenge.count == GarageCrypto.challengeLength else {
            throw ClientError.badResponse("challenge was \(challenge.count) bytes")
        }
        let frame = CommandFrame.signed(opcode, challenge: challenge, key: key, clientID: clientID, deviceID: info.deviceID)
        try await write(.command, frame.encoded, note: "\(opcode.label) signed")
    }

    func readRSSI() async throws -> Int {
        try await connection.readRSSI()
    }

    func disconnect() {
        eventTask?.cancel()
        onStatus = nil
        onDisconnect = nil
        connection.disconnect()
        log.record(.event, note: "Disconnected by app")
    }

    // MARK: Logged GATT operations

    private func read(_ characteristic: GarageCharacteristic, note: String) async throws -> Data {
        do {
            let value = try await connection.read(characteristic)
            log.record(.rx, characteristic, value, note: note)
            return value
        } catch {
            log.record(.error, characteristic, note: "read failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func write(_ characteristic: GarageCharacteristic, _ value: Data, note: String) async throws {
        log.record(.tx, characteristic, value, note: note)
        do {
            try await connection.write(characteristic, value)
        } catch {
            let detail: String
            if case let LinkError.att(att) = error {
                detail = "ATT 0x\(String(att.rawValue, radix: 16)) \(att)"
            } else {
                detail = error.localizedDescription
            }
            log.record(.error, characteristic, note: "write rejected: \(detail)")
            throw error
        }
    }
}
